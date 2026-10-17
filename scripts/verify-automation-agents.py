#!/usr/bin/env python3
"""Verify real Codex or Claude stages through Orca on an isolated board (uses the signed-in account)."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', required=True, type=Path)
    parser.add_argument('--orca', required=True, type=Path)
    parser.add_argument('--worktree', required=True)
    parser.add_argument('--agent', required=True, choices=['codex', 'claude'])
    parser.add_argument('--process-preset', help='Preset ID or auto for actual agent process selection')
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    cli = str(args.cli.resolve())
    service = args.cli.resolve().with_name('workboard-service')
    def orca(*command):
        response = json.loads(subprocess.check_output([str(args.orca), *command, '--json'], timeout=20))
        if not response.get('ok'):
            raise RuntimeError(response.get('error'))
        return response['result']
    worktree = orca('worktree', 'show', '--worktree', 'id:' + args.worktree)['worktree']
    skill = out / 'smoke-skill' / 'SKILL.md'
    skill.parent.mkdir()
    skill.write_text('---\nname: workboard-smoke\ndescription: Verify a board stage callback.\n---\n\nRead only the first heading of README.md. Include WORKBOARD_SKILL_VERIFIED in the report summary. Do not edit source or create files. Report exactly once through the command in the stage prompt.\n')
    workflow = None
    closed = []
    task = None
    with tempfile.TemporaryDirectory(prefix='wb-model-', dir='/tmp') as temporary:
        env = {k: v for k, v in os.environ.items() if k not in ('WORKBOARD_AGENT', 'CODEX_THREAD_ID', 'WORKBOARD_WIDGET_SNAPSHOT', 'CLAUDECODE')}
        env.update(WORKBOARD_DATA_DIR=str(out / 'board'), WORKBOARD_SOCKET=str(Path(temporary) / 'board.sock'), WORKBOARD_CLI_BIN=cli)
        log = (out / 'service.log').open('ab')
        process = subprocess.Popen([str(service)], env=env, stdout=log, stderr=log)
        def board(*command):
            response = json.loads(subprocess.check_output([cli, *command, '--json'], env=env, timeout=45))
            if not response.get('ok'):
                raise RuntimeError(response.get('error'))
            return response['result']
        try:
            for _ in range(100):
                if Path(env['WORKBOARD_SOCKET']).exists():
                    break
                time.sleep(.05)
            # These are scoped smoke-test commands. No sandbox or permission bypass is used.
            command = ['codex', 'exec', '--sandbox', 'workspace-write', '-c', 'model_reasoning_effort="low"'] if args.agent == 'codex' else ['claude', '--print', '--permission-mode', 'auto']
            runner = out / 'agent-runner.py'
            runner.write_text("import os,subprocess,sys\nfrom pathlib import Path\nenv=dict(os.environ)\nenv.pop('CLAUDECODE',None)\nlog=Path(" + repr(str(out)) + ")/('agent-'+os.environ['WORKBOARD_AUTOMATION_ATTEMPT']+'.log')\nwith log.open('wb') as output: result=subprocess.run(" + repr(command) + "+[sys.argv[1]],env=env,stdout=output,stderr=subprocess.STDOUT)\nsys.exit(result.returncode)\n")
            command = [os.sys.executable, str(runner)]
            board('plugin', 'install', str(ROOT / 'plugins/orca'))
            board('plugin', 'enable', 'orca', '--executable', str(args.orca), '--config', json.dumps({'repos': ['id:' + worktree['repoId']], 'automation_agent_commands': {args.agent: command}}))
            project = board('project', 'add', '--name', 'Real agent smoke verification', '--directory', worktree['path'])['project_id']
            rule = {'id': 'model-smoke', 'status': 'in_progress', 'action': 'development' if args.agent == 'codex' or args.process_preset else 'stage', 'stage': 'preflight', 'skills': [str(skill)], 'prompt': 'This is a small transport verification. Read only the README first heading and the required skill. No implementation change is required. Do not audit the repository.', 'instructions': 'Include WORKBOARD_PROMPT_VERIFIED and WORKBOARD_INSTRUCTIONS_VERIFIED in the report summary. Complete this stage promptly, then report and exit.'}
            config = {'plugin_id': 'orca', 'method': 'automation.start', 'resource_key': args.worktree, 'params': {'worktree_id': args.worktree, 'agent': args.agent, 'reviewer': args.agent}, 'max_reworks': 0, 'timeout_seconds': 300, 'rules': [rule]}
            if args.process_preset:
                config.update(process_preset=args.process_preset)
            config_path = out / 'configuration.json'
            config_path.write_text(json.dumps(config, indent=2))
            board('automation', 'set-defaults', project, '--configuration', str(config_path))
            task = board('task', 'add', '--project', project, '--title', 'Verify real ' + args.agent + ' stage callbacks', '--goal', 'Verify automation reporting only. Read the first README heading. Make no source changes.', '--completion-criteria', 'Report the README heading and all required skill, prompt, and instruction markers; preserve source; do not deploy')['task_id']
            revision = board('task', 'show', task)['task']['revision']
            board('task', 'start', task, '--agent', 'user', '--expected-revision', str(revision))
            previous = None
            started = time.monotonic()
            expected = 'awaiting_approval' if args.agent == 'codex' or args.process_preset else 'waiting'
            while time.monotonic() - started < 600:
                workflow = board('automation', 'show', task)['automation']
                state = (workflow['state'], workflow['stage'], len(workflow['attempts']))
                if state != previous:
                    print(args.agent + ':', *state, flush=True)
                    previous = state
                if workflow['state'] in (expected, 'blocked'):
                    break
                time.sleep(1)
            if workflow['state'] != expected:
                raise RuntimeError(workflow.get('message', 'Agent smoke verification timed out'))
            if args.process_preset == 'auto' and (not workflow.get('process', {}).get('preset') or not workflow['process'].get('selection_reason')):
                raise RuntimeError('The real agent did not choose and explain a process preset')
            for attempt in workflow['attempts']:
                summary = (attempt.get('result') or {}).get('summary', '')
                if not attempt['worker_exited'] or not all(marker in summary for marker in ['WORKBOARD_SKILL_VERIFIED', 'WORKBOARD_PROMPT_VERIFIED', 'WORKBOARD_INSTRUCTIONS_VERIFIED']):
                    raise RuntimeError('The real agent did not report all required markers and confirm process exit')
        finally:
            if task:
                workflow = board('automation', 'show', task)['automation']
                for attempt in workflow['attempts']:
                    handle = attempt['receipt'].get('terminal', {}).get('handle')
                    if handle and attempt['worker_exited']:
                        orca('terminal', 'close', '--terminal', handle)
                        closed.append(handle)
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
            log.close()
            evidence = {'verified_at': dt.datetime.now(dt.timezone.utc).isoformat(), 'agent': args.agent, 'actual_model_calls': bool(workflow and any(a.get('result') for a in workflow['attempts'])), 'task_id': task, 'state': workflow['state'] if workflow else None, 'process': workflow.get('process') if workflow else None, 'attempts': workflow['attempts'] if workflow else [], 'closed_terminals': closed}
            (out / 'evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print('Evidence:', out / 'evidence.json')


if __name__ == '__main__':
    main()
