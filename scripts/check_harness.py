#!/usr/bin/env python3
"""Check the offline project map; never run its actions or access accounts."""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
DOMAINS = {'android', 'ios', 'worker', 'feedback', 'agent-interface', 'open-source'}
MODES = {'technical', 'agent_ui', 'human_physical'}
STATES = {'needs_review', 'pending', 'blocked', 'verified'}


def text(value):
    return isinstance(value, str) and bool(value.strip())


def local_source(value, root):
    if not text(value) or '://' in value:
        return False
    path = Path(value)
    if path.is_absolute() or '..' in path.parts:
        return False
    target = (root / path).resolve()
    return root.resolve() in target.parents and target.is_file()


def validate(contract, root):
    errors = []
    if not isinstance(contract, dict):
        return ['contract must be an object']
    if type(contract.get('schemaVersion')) is not int or contract['schemaVersion'] != 1:
        errors.append('unsupported schemaVersion')
    if contract.get('executionAuthorizedByContract') is not False:
        errors.append('contract cannot grant execution permissions')
    for key in ['objective', 'owner', 'canonicalSource', 'updatedAt']:
        if not text(contract.get(key)):
            errors.append('missing project ' + key)
    if not local_source(contract.get('canonicalSource'), root):
        errors.append('canonicalSource must be an existing repository file')
    projects = contract.get('subprojects')
    if not isinstance(projects, list):
        return errors + ['subprojects must be a list']
    seen = set()
    for project in projects:
        if not isinstance(project, dict):
            errors.append('subproject must be an object')
            continue
        identifier = project.get('id')
        if not text(identifier) or identifier in seen:
            errors.append('missing or duplicate subproject id')
        if text(identifier):
            seen.add(identifier)
        for key in ['objective', 'owner', 'nextAction']:
            if not text(project.get(key)):
                errors.append(str(identifier) + ': missing ' + key)
        if not text(project.get('status')) or project['status'] not in STATES:
            errors.append(str(identifier) + ': unknown status')
        for key in ['acceptance', 'dependencies']:
            values = project.get(key)
            if not isinstance(values, list) or not values or not all(text(v) for v in values):
                errors.append(str(identifier) + ': missing ' + key)
        sources = project.get('sources')
        if not isinstance(sources, list) or not sources or not all(local_source(p, root) for p in sources):
            errors.append(str(identifier) + ': sources must be existing repository files')
        cases = project.get('qa')
        if not isinstance(cases, list) or not cases:
            errors.append(str(identifier) + ': missing QA')
            continue
        for case in cases:
            if not isinstance(case, dict):
                errors.append(str(identifier) + ': invalid QA case')
                continue
            if not text(case.get('mode')) or case['mode'] not in MODES:
                errors.append(str(identifier) + ': unknown QA mode')
            for key in ['scenario', 'expected', 'reason', 'evidence']:
                if not text(case.get(key)):
                    errors.append(str(identifier) + ': missing QA ' + key)
        if project.get('status') == 'verified' and not text(project.get('completionEvidence')):
            errors.append(str(identifier) + ': verified requires completion evidence')
    if seen != DOMAINS:
        errors.append('project map must cover exactly: ' + ', '.join(sorted(DOMAINS)))
    for filename in ['AGENTS.md', 'README.md']:
        path = root / filename
        if not path.is_file() or 'docs/project/harness.md' not in path.read_text():
            errors.append(filename + ' must link the project harness')
    return errors


def main():
    try:
        contract = json.loads((ROOT / 'docs/project/harness.json').read_text())
        errors = validate(contract, ROOT)
    except (OSError, ValueError) as error:
        errors = ['cannot read project contract: ' + type(error).__name__]
    print(json.dumps({'status': 'invalid' if errors else 'consistent', 'errors': errors,
                      'limit': 'Offline structure only; not approval, QA or permission.'}))
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
