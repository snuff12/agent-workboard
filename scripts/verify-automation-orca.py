#!/usr/bin/env python3
"""Verify real Orca terminals with a synthetic agent and an isolated persistent board."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--orca", required=True, type=Path)
    parser.add_argument("--worktree", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    if (args.output / "board").exists():
        parser.error("Choose a fresh output directory so previous evidence is preserved.")
    cli = ROOT / "target/debug/workboard"
    service_binary = ROOT / "target/debug/workboard-service"

    def orca(*command):
        response = json.loads(subprocess.check_output([str(args.orca), *command, "--json"], timeout=15))
        if not response.get("ok"):
            raise RuntimeError(response.get("error"))
        return response["result"]

    worktree = orca("worktree", "show", "--worktree", "id:" + args.worktree)["worktree"]
    if worktree["hostId"] != "local":
        parser.error("This check supports a local worktree only.")
    source = worktree["path"]
    with tempfile.TemporaryDirectory(prefix="wb-live-", dir="/tmp") as temporary:
        env = {key: value for key, value in os.environ.items() if key not in ("WORKBOARD_AGENT", "CODEX_THREAD_ID", "WORKBOARD_WIDGET_SNAPSHOT")}
        env.update(WORKBOARD_DATA_DIR=str(args.output / "board"), WORKBOARD_SOCKET=str(Path(temporary) / "board.sock"), WORKBOARD_CLI_BIN=str(cli))
        agent = args.output / "synthetic-agent.py"
        agent.write_text("""import json, os, subprocess, sys
from pathlib import Path
cli=__CLI__
source=__SOURCE__
task=os.environ['WORKBOARD_AUTOMATION_TASK']
workflow=json.loads(subprocess.check_output([cli,'automation','show',task,'--json']))['result']['automation']
stage=workflow['stage']
reviews=sum(item['stage']=='review' for item in workflow['attempts'])
outcome='changes_requested' if stage=='review' and reviews==1 else 'pass'
evidence=Path(__OUTPUT__)/('report-'+os.environ['WORKBOARD_AUTOMATION_ATTEMPT']+'.txt')
evidence.write_text('Synthetic '+stage+' result. This verifies transport only; no model was called and no project source was edited.\\n')
sys.exit(subprocess.call([cli,'automation','report','--source-dir',source,'--outcome',outcome,'--summary','Synthetic '+stage+' transport check','--evidence',str(evidence),'--request-id','live-report:'+os.environ['WORKBOARD_AUTOMATION_ATTEMPT'],'--json']))
""".replace("__CLI__", repr(str(cli))).replace("__SOURCE__", repr(source)).replace("__OUTPUT__", repr(str(args.output))))
        log = (args.output / "service.log").open("ab")
        service = subprocess.Popen([str(service_binary)], env=env, stdout=log, stderr=log)
        task = None
        closed = []

        def board(*command):
            result = subprocess.run([str(cli), *command, "--json"], env=env, text=True, capture_output=True, timeout=40)
            response = json.loads(result.stdout)
            if not response.get("ok"):
                raise RuntimeError(response.get("error"))
            return response["result"]

        workflow = None
        try:
            for _ in range(100):
                if Path(env["WORKBOARD_SOCKET"]).exists():
                    break
                time.sleep(.05)
            board("plugin", "install", str(ROOT / "plugins/orca"))
            board("plugin", "enable", "orca", "--executable", str(args.orca), "--config", json.dumps({"repos": ["id:" + worktree["repoId"]], "automation_agent_commands": {"codex": [sys.executable, str(agent)]}}))
            project = board("project", "add", "--name", "Automation runtime verification", "--directory", source)["project_id"]
            task = board("task", "add", "--project", project, "--title", "Verify automatic development stages", "--goal", "Verify the real Orca transport with harmless synthetic agents", "--completion-criteria", "Six stages report and exit once; final approval remains pending")["task_id"]
            board("automation", "configure", task, "--executor", "orca", "--resource-key", args.worktree, "--params", json.dumps({"worktree_id": args.worktree, "agent": "codex", "reviewer": "codex"}))
            board("automation", "start", task)
            started = time.monotonic()
            previous = None
            while time.monotonic() - started < 90:
                workflow = board("automation", "show", task)["automation"]
                status = (workflow["state"], workflow["stage"], len(workflow["attempts"]))
                if status != previous:
                    print("Workflow:", *status, flush=True)
                    previous = status
                if workflow["state"] == "blocked":
                    raise RuntimeError(workflow["message"])
                if workflow["state"] == "awaiting_approval" and all(item["receipt"].get("terminal") for item in workflow["attempts"]):
                    break
                time.sleep(.2)
            expected = ["preflight", "work", "review", "rework", "review", "release"]
            if workflow["state"] != "awaiting_approval" or [item["stage"] for item in workflow["attempts"]] != expected or not all(item["worker_exited"] for item in workflow["attempts"]):
                raise RuntimeError("The expected workflow did not finish exactly once.")
        finally:
            if task:
                try:
                    workflow = board("automation", "show", task)["automation"]
                    for item in workflow["attempts"]:
                        handle = item["receipt"].get("terminal", {}).get("handle")
                        if handle:
                            orca("terminal", "close", "--terminal", handle)
                            closed.append(handle)
                except Exception as error:
                    print("Cleanup needs inspection:", str(error), file=sys.stderr)
            if service.poll() is None:
                service.terminate()
                service.wait(timeout=10)
            log.close()
            evidence = {"verified_at": dt.datetime.now(dt.timezone.utc).isoformat(), "kind": "real Orca CLI/terminal and board service; synthetic agent", "actual_model_calls": False, "native_ui": False, "task_id": task, "state": workflow.get("state") if workflow else None, "stages": [{"stage": item["stage"], "state": item["state"], "worker_exited": item["worker_exited"], "outcome": (item.get("result") or {}).get("outcome"), "source_version": (item.get("result") or {}).get("source_version"), "terminal": item["receipt"].get("terminal", {}).get("handle")} for item in workflow.get("attempts", [])] if workflow else [], "closed_terminals": closed}
            (args.output / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print("Evidence:", args.output / "evidence.json")


if __name__ == "__main__":
    main()
