#!/usr/bin/env python3
"""Render real SwiftUI views from disposable CLI/service fixtures, without user data or accounts."""
import datetime
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "target/debug/workboard"
SERVICE = ROOT / "target/debug/workboard-service"


def main():
    environment = dict(os.environ)
    # An agent session's identity would make the CLI act as that agent on the fixture tasks.
    for key in ("WORKBOARD_DATA_DIR", "WORKBOARD_SOCKET", "WORKBOARD_WIDGET_SNAPSHOT", "WORKBOARD_AGENT", "CODEX_THREAD_ID"):
        environment.pop(key, None)
    with tempfile.TemporaryDirectory(prefix="awb-pixels-", dir="/tmp") as temporary:
        data = Path(temporary) / "data"
        socket = Path(temporary) / "s.sock"
        process = subprocess.Popen(
            [str(SERVICE), "--data-dir", str(data), "--socket", str(socket)],
            env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            deadline = time.monotonic() + 5
            while not socket.exists():
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("Disposable preview service did not start")
                time.sleep(0.02)

            def run(*arguments):
                response = subprocess.run(
                    [str(CLI), "--data-dir", str(data), "--socket", str(socket), "--json", *map(str, arguments)],
                    env=environment, cwd=ROOT, capture_output=True, text=True, check=True,
                )
                envelope = json.loads(response.stdout)
                if not envelope["ok"]:
                    raise RuntimeError(envelope)
                return envelope["result"]

            def rpc(method, **parameters):
                return run("rpc", method, "--params", json.dumps(parameters, ensure_ascii=False))

            project = run("project", "add", "--name", "Refresh the brand website", "--directory", ROOT)["project_id"]
            parent = run("task", "add", "--project", project, "--title", "Refresh the homepage",
                         "--goal", "Build an opening screen that explains the service clearly")["task"]

            def task(title, **parameters):
                arguments = ["task", "add", "--project", project, "--parent", parent["id"], "--title", title]
                for key, value in parameters.items():
                    arguments.extend(["--" + key.replace("_", "-"), str(value)])
                return run(*arguments)["task"]

            design = task("Review landing page design", goal="Review light and dark screens and apply changes", priority=3)
            implementation = task("Implement the landing page", goal="Implement the approved design and accessibility requirements", priority=2)
            rpc("task.dependency.add", task_id=implementation["id"], depends_on_id=design["id"])
            current = rpc("task.get", task_id=design["id"])["task"]
            rpc("task.checklist.add", task_id=design["id"], text="Check mobile and dark layouts",
                required=True, expected_revision=current["revision"])
            run("task", "start", design["id"], "--agent", "design-agent")
            run("task", "review", design["id"], "--summary", "Review the mockup and supporting evidence")
            today = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9))).replace(
                hour=9, minute=0, second=0, microsecond=0)
            for title, hour, duration in [
                ("Design review", 10, 1), ("Accessibility review", 11, 2),
                ("Prepare usability testing", 14, 1), ("Design the search screen", 10, 2),
            ]:
                start = today.replace(hour=hour)
                task(title, scheduled_start=start.isoformat(),
                     scheduled_end=(start + datetime.timedelta(hours=duration)).isoformat(), time_zone="Asia/Seoul")
            task("Edit content copy", scheduled_start=today.date().isoformat(),
                 scheduled_end=(today + datetime.timedelta(days=1)).date().isoformat(), time_zone="Asia/Seoul")
            task("Write the release checklist", goal="Document logging, backup, and rollback procedures")
            task("Localize the homepage", goal="Plan after the first release", status="backlog")
            dropped = task("Animate the hero banner", goal="Dropped in favor of a static layout")
            rpc("task.update", task_id=dropped["id"], expected_revision=dropped["revision"], status="canceled")
            for title in ("Draft the old hero copy", "Compare carousel libraries"):
                rpc("task.delete", task_id=task(title, goal="Replaced by the new layout")["id"])
            rpc("inbox.capture", title="Customer feedback on search improvements", source="https://example.com/feedback",
                note="Turn this into a search task at the next planning session")
            rpc("inbox.capture", title="Feedback that mobile buttons are too small", note="Review the screen recording before creating a task")
            rpc("view.save", name="Ready to start", filters={"ready_only": True}, layout="board")
            subprocess.run(
                ["macos/Tests/render-previews.sh"], cwd=ROOT, check=True,
                env={**environment, "WORKBOARD_BIN": str(CLI), "WORKBOARD_DATA_DIR": str(data), "WORKBOARD_SOCKET": str(socket)},
            )
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)


if __name__ == "__main__":
    main()
