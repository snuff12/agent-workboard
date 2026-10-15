#!/usr/bin/env python3
"""Measure optional plugin installation costs in an isolated service without running external integrations."""
import json
import os
from pathlib import Path
import socket
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "target/release/workboard"
SERVICE = ROOT / "target/release/workboard-service"


def tree_bytes(directory):
    return sum(item.stat().st_size for item in directory.rglob("*") if item.is_file() and not item.is_symlink())


def main():
    report = {"measured_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
              "scope": "CLI round trips to the same local service, without running Google/amem/Python. Excludes GUI startup time.",
              "base_bundle_bytes": tree_bytes(ROOT / "dist/Agent Workboard.app"),
              "stages": []}
    with tempfile.TemporaryDirectory(prefix="awb-measure-", dir="/tmp") as temporary:
        directory = Path(temporary)
        data = directory / "data"
        endpoint = directory / "s.sock"
        empty_path = directory / "empty-path"
        empty_path.mkdir()
        environment = {**os.environ, "HOME": str(directory), "PATH": str(empty_path)}
        environment.pop("WORKBOARD_WIDGET_SNAPSHOT", None)
        started = time.perf_counter()
        server = subprocess.Popen([str(SERVICE), "--data-dir", str(data), "--socket", str(endpoint)],
                                  env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            while True:
                if server.poll() is not None:
                    raise RuntimeError("The isolated service exited during startup")
                try:
                    with socket.socket(socket.AF_UNIX) as connection:
                        connection.connect(str(endpoint))
                    break
                except OSError:
                    if time.perf_counter() - started > 5:
                        raise TimeoutError("Service readiness timed out")
                    time.sleep(0.005)
            report["service_ready_ms_single_sample"] = round((time.perf_counter() - started) * 1000, 2)

            def cli(*arguments):
                result = subprocess.run([str(CLI), "--data-dir", str(data), "--socket", str(endpoint), "--json", *arguments],
                                        env=environment, capture_output=True, text=True, timeout=10)
                payload = json.loads(result.stdout)
                if result.returncode or not payload["ok"]:
                    raise RuntimeError(payload)
                return payload

            for stage in ["no_plugins", "installed_disabled", "enabled_without_invocation"]:
                if stage == "installed_disabled":
                    for plugin in ["agent-memory", "google-workspace"]:
                        cli("plugin", "install", str(ROOT / "plugins" / plugin))
                elif stage == "enabled_without_invocation":
                    cli("plugin", "enable", "agent-memory", "--config", '{"executable":"/nonexistent/amem"}')
                    cli("plugin", "enable", "google-workspace", "--config", '{"calendar_enabled":true,"gmail_enabled":false}')
                cli("doctor")
                samples = []
                for _ in range(15):
                    before = time.perf_counter()
                    cli("board")
                    samples.append((time.perf_counter() - before) * 1000)
                rss_kib = int(subprocess.check_output(["/bin/ps", "-o", "rss=", "-p", str(server.pid)], text=True).strip())
                report["stages"].append({"stage": stage, "samples": len(samples),
                                         "cli_board_median_ms": round(statistics.median(samples), 2),
                                         "cli_board_min_ms": round(min(samples), 2),
                                         "cli_board_max_ms": round(max(samples), 2),
                                         "service_rss_kib": rss_kib,
                                         "installed_plugin_bytes": tree_bytes(data / "plugins"),
                                         "plugin_data_created": (data / "plugin-data").exists()})
            assert not (data / "plugin-data").exists(), "Plugin execution data was created before an explicit call"
        finally:
            if server.poll() is None:
                server.terminate()
            server.wait(timeout=5)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
