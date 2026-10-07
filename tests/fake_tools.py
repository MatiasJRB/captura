"""Fake command-line tools for setup-script tests. No network, no real Xcode or rclone.

`install(directory, spec)` writes one executable per tool name. Each answers from
`spec[name]`: a list of rules `{"match": [args...], "stdout", "stderr", "rc",
"json_output": {...}}`; the first rule whose `match` items all appear in the arguments wins.
Unknown invocations exit 127, like a missing command. Reuse one directory across tests
and only the spec changes: the shims themselves are written once. With FAKE_TOOLS_LOG set
in the environment, every call appends {"tool", "args", "env"} as one JSON line there, so
tests can check what reached a child process.
"""
import json
import os
from pathlib import Path
import sys

SHIM = '''#!{python}
import json, os, sys
spec = json.load(open({spec!r}))
name = os.path.basename(sys.argv[0])
args = sys.argv[1:]
if os.environ.get('FAKE_TOOLS_LOG'):
    with open(os.environ['FAKE_TOOLS_LOG'], 'a') as log:
        log.write(json.dumps(dict(tool=name, args=args, env=dict(os.environ))) + '\\n')
for rule in spec.get(name, []):
    if all(item in args for item in rule.get('match', [])):
        if 'json_output' in rule and '--json-output' in args:
            with open(args[args.index('--json-output') + 1], 'w') as out:
                json.dump(rule['json_output'], out)
        sys.stdout.write(rule.get('stdout', ''))
        sys.stderr.write(rule.get('stderr', ''))
        sys.exit(rule.get('rc', 0))
sys.exit(127)
'''


def install(directory, spec):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    spec_path = directory / 'fake-tools.json'
    spec_path.write_text(json.dumps(spec))
    shim = SHIM.format(python=sys.executable, spec=str(spec_path))
    for name in spec:
        path = directory / name
        # Keep unchanged shims: on macOS a freshly written executable starts noticeably slower.
        if not path.exists() or path.read_text() != shim:
            path.write_text(shim)
            os.chmod(path, 0o755)
    return directory


def script(directory, name, body):
    """A tiny shell tool, for programs that only need fixed output."""
    path = Path(directory) / name
    path.write_text('#!/bin/sh\n' + body + '\n')
    os.chmod(path, 0o755)
    return path
