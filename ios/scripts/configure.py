#!/usr/bin/env python3
"""Write ios/Config/Captura.local.xcconfig, the personal settings of a Captura iOS build.

Python 3 standard library only. No network, no downloads. An iOS OAuth client ID and an
Apple team ID are identifiers, not secrets; nothing secret is read or printed.

    python3 ios/scripts/configure.py --bundle-id com.yourname.captura \\
        --google-client-id 1234-abc.apps.googleusercontent.com [--hosted-domain example.org]
    python3 ios/scripts/configure.py                      # fill in the team after Xcode sign-in
    python3 ios/scripts/configure.py --team ABCDE12345    # set the team explicitly
    python3 ios/scripts/configure.py --adopt-xcode-team   # move a team picked in Xcode here
"""
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
LOCAL = Path('ios/Config/Captura.local.xcconfig')
PROJECT = Path('ios/Captura.xcodeproj/project.pbxproj')
SCRIPT = 'python3 ios/scripts/configure.py'

KEY_BUNDLE = 'CAPTURA_BUNDLE_ID'
KEY_TEAM = 'CAPTURA_DEVELOPMENT_TEAM'
KEY_CLIENT = 'CAPTURA_GOOGLE_IOS_CLIENT_ID'
KEY_REVERSED = 'CAPTURA_GOOGLE_REVERSED_CLIENT_ID'
KEY_DOMAIN = 'CAPTURA_GOOGLE_HOSTED_DOMAIN'

CLIENT_SUFFIX = '.apps.googleusercontent.com'
REVERSED_PREFIX = 'com.googleusercontent.apps.'
TEAM_PATTERN = re.compile(r'[A-Z0-9]{10}')
PLACEHOLDER_TEAM = '$(CAPTURA_DEVELOPMENT_TEAM)'


class ConfigError(Exception):
    """A value or state the person has to fix; the message says how."""


def _clean(value):
    return (value or '').strip().strip('"\'').strip()


def normalize_bundle_id(value):
    bundle = _clean(value)
    if not bundle:
        raise ConfigError('The bundle ID is empty. Use something unique to you, '
                          'for example com.yourname.captura.')
    if 'example' in bundle.lower():
        raise ConfigError(f'"{bundle}" is the example bundle ID. Use one unique to you, '
                          'for example com.yourname.captura.')
    if (len(bundle) > 155 or '..' in bundle
            or not re.fullmatch(r'[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+', bundle)):
        raise ConfigError(f'"{bundle}" is not a valid bundle ID. Use letters, digits, hyphens '
                          'and dots, for example com.yourname.captura.')
    return bundle


def normalize_client_id(value):
    """Returns the iOS client ID. Accepts the reversed form (the "iOS URL scheme")."""
    client = _clean(value)
    if client.lower().startswith(REVERSED_PREFIX):
        client = client[len(REVERSED_PREFIX):] + CLIENT_SUFFIX
    if not client:
        raise ConfigError('The Google client ID is empty. Copy the Client ID of the iOS '
                          'OAuth client from Google Cloud.')
    if not client.lower().endswith(CLIENT_SUFFIX):
        raise ConfigError(f'"{client}" is not a Google client ID: it must end in {CLIENT_SUFFIX}. '
                          'Copy the Client ID of the iOS OAuth client.')
    prefix = client[:-len(CLIENT_SUFFIX)]
    if not re.fullmatch(r'[0-9]+-[A-Za-z0-9_-]+', prefix):
        raise ConfigError(f'"{client}" is not a Google client ID. It looks like '
                          f'123456789012-abc...{CLIENT_SUFFIX}.')
    number = prefix.split('-', 1)[0]
    if 'example' in client.lower() or set(number) == {'0'}:
        raise ConfigError('That is the example client ID. Copy the Client ID of your own '
                          'iOS OAuth client from Google Cloud.')
    return prefix + CLIENT_SUFFIX


def reversed_client_id(client_id):
    return REVERSED_PREFIX + client_id[:-len(CLIENT_SUFFIX)]


def normalize_hosted_domain(value):
    domain = _clean(value).lower()
    if domain.startswith('@'):
        domain = domain[1:]
    if not domain:
        return ''
    if 'example' in domain:
        raise ConfigError(f'"{domain}" is an example domain. Leave it out, or use your Google '
                          'Workspace domain.')
    labels = domain.split('.')
    if len(labels) < 2 or not all(re.fullmatch(r'[a-z0-9]([a-z0-9-]*[a-z0-9])?', l) for l in labels):
        raise ConfigError(f'"{domain}" is not a domain. Use only the Workspace domain, '
                          'for example yourcompany.com, without @ or https://.')
    return domain


def normalize_team(value):
    team = _clean(value).upper()
    if not TEAM_PATTERN.fullmatch(team):
        raise ConfigError(f'"{_clean(value)}" is not an Apple team ID: it has 10 letters and digits, '
                          'for example ABCDE12345.')
    return team


def read_xcconfig(path):
    """(KEY -> value, keys whose value was cut by "//"). `//` starts a comment anywhere."""
    values, truncated = {}, []
    for line in Path(path).read_text(encoding='utf-8').splitlines():
        code, marker, _ = line.partition('//')
        match = re.fullmatch(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*', code)
        if not match:
            continue
        key, value = match.groups()
        values[key] = value
        # "KEY = https://x" loses everything after "https:"; "KEY = x // note" is a comment.
        if marker and value and not code[-1:].isspace():
            truncated.append(key)
    return values, truncated


def render_xcconfig(bundle, team, client, domain):
    for value in (bundle, team, client, domain):
        if '//' in value:  # Defensive: validation never lets "/" through.
            raise ConfigError('A value contains "//", which starts a comment in an .xcconfig.')
    lines = [
        '// Written by ios/scripts/configure.py. Git ignores this file: it is yours.',
        '// To change it, run the script again (with --force to replace everything).',
        '// Never put "//" inside a value: it starts a comment.',
        '',
        '// Unique to you; must match the bundle ID of the Google "iOS" OAuth client.',
        f'{KEY_BUNDLE} = {bundle}',
        '// Apple team (a free Personal Team works).',
        f'{KEY_TEAM} = {team}',
        '// Google "iOS" OAuth client and its URL scheme (derived from the client ID).',
        f'{KEY_CLIENT} = {client}',
        f'{KEY_REVERSED} = {reversed_client_id(client)}',
        '// Optional: only offer accounts of this Google Workspace domain.',
        f'{KEY_DOMAIN} = {domain}',
    ]
    return '\n'.join(line.rstrip() for line in lines) + '\n'


def write_atomically(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temp = tempfile.mkstemp(prefix='.captura-', suffix='.xcconfig', dir=path.parent)
    try:
        with os.fdopen(handle, 'w', encoding='utf-8') as stream:
            stream.write(text)
        os.chmod(temp, 0o644)
        os.replace(temp, path)
    except BaseException:
        if os.path.exists(temp):
            os.unlink(temp)
        raise


def set_team_in_text(text, team):
    line = f'{KEY_TEAM} = {team}'.rstrip()
    pattern = re.compile(r'^[ \t]*' + KEY_TEAM + r'[ \t]*=.*$', re.MULTILINE)
    if pattern.search(text):
        return pattern.sub(lambda _: line, text, count=1)
    return text.rstrip('\n') + '\n' + line + '\n'


def run(command, cwd=None, timeout=60):
    try:
        return subprocess.run(command, cwd=cwd, capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None


def xcode_teams():
    """Teams Xcode lists after signing in at Xcode > Settings > Apple Accounts.

    Xcode keeps them in its preferences (keys such as IDEProvisioningTeams or
    IDEProvisioningTeamByIdentifier). The layout is undocumented, so any dictionary that
    carries a `teamID` under those keys counts. Returns [{'id', 'name', 'free'}].
    """
    result = run(['defaults', 'export', 'com.apple.dt.Xcode', '-'])
    if result is None or result.returncode != 0 or not result.stdout:
        return []
    try:
        prefs = plistlib.loads(result.stdout)
    except Exception:
        return []
    teams = {}

    def visit(node, key_hint=None):
        if isinstance(node, dict):
            team = node.get('teamID') or node.get('TeamID') or node.get('teamId')
            if team is None and key_hint and TEAM_PATTERN.fullmatch(key_hint):
                team = key_hint
            if isinstance(team, str) and TEAM_PATTERN.fullmatch(team):
                name = node.get('teamName') or node.get('name') or ''
                free = bool(node.get('isFreeProvisioningTeam')) or '(Personal Team)' in str(name)
                known = teams.setdefault(team, {'id': team, 'name': str(name), 'free': free})
                known['free'] = known['free'] or free
                known['name'] = known['name'] or str(name)
            for child_key, child in node.items():
                visit(child, child_key if isinstance(child_key, str) else None)
        elif isinstance(node, list):
            for child in node:
                visit(child)

    if isinstance(prefs, dict):
        for key, value in prefs.items():
            if 'ProvisioningTeam' in key:
                visit(value)
    return sorted(teams.values(), key=lambda t: (not t['free'], t['name'], t['id']))


def describe(team):
    label = team['name'] or 'unnamed team'
    if team['free'] and '(Personal Team)' not in label:
        label += ', Personal Team'
    return f"{team['id']} ({label})"


def xcode_is_running():
    result = run(['pgrep', '-x', 'Xcode'], timeout=10)
    return result is not None and result.returncode == 0


def project_team(root):
    """Team that Xcode's Signing menu wrote into the tracked project file.

    Returns (team, unexpected_lines, staged). Raises ConfigError when Git cannot tell.
    """
    staged = run(['git', 'diff', '--cached', '--quiet', '--', str(PROJECT)], cwd=root)
    diff = run(['git', 'diff', '--no-color', '--no-ext-diff', '-U0', '--', str(PROJECT)], cwd=root)
    if staged is None or diff is None or diff.returncode != 0 or staged.returncode not in (0, 1):
        raise ConfigError('Git could not compare the Xcode project with the downloaded version. '
                          'Run this from a folder created with "git clone", and pass the team '
                          'with --team instead.')
    teams, unexpected = [], []
    for line in diff.stdout.decode('utf-8', errors='replace').splitlines():
        if not line or line[0] not in '+-' or line.startswith(('+++', '---')):
            continue
        body = line[1:].strip()
        match = re.fullmatch(r'(DEVELOPMENT_TEAM|DevelopmentTeam)\s*=\s*"?([^";]*)"?;', body)
        if match:
            value = match.group(2)
            if line.startswith('+') and value != PLACEHOLDER_TEAM:
                teams.append(value)
            continue
        if re.fullmatch(r'ProvisioningStyle\s*=\s*\w+;', body) and line.startswith('+'):
            continue
        unexpected.append(line)
    found = sorted(set(teams))
    if len(found) > 1:
        raise ConfigError('Xcode wrote more than one team into the project (' + ', '.join(found) +
                          '). Pick one and pass it with --team.')
    return (found[0] if found else None), unexpected, staged.returncode == 1


def restore_project(root):
    result = run(['git', 'checkout', '--', str(PROJECT)], cwd=root)
    check = run(['git', 'diff', '--quiet', '--', str(PROJECT)], cwd=root)
    return result is not None and result.returncode == 0 and check is not None and check.returncode == 0


def adopt_from_project(root):
    """Reads the team written by Xcode; does not touch any file yet."""
    if xcode_is_running():
        raise ConfigError('Xcode is open. Quit Xcode first (Xcode > Quit Xcode), so it cannot '
                          'write the team back into the project, then run this again.')
    team, unexpected, staged = project_team(root)
    if staged:
        raise ConfigError(f'{PROJECT} has changes staged in Git. Unstage them first '
                          f'("git restore --staged {PROJECT}"), then run this again.')
    if team is None:
        raise ConfigError('Xcode has not written a team into the project. In Xcode, select '
                          'the Captura project > target Captura > Signing & Capabilities, pick '
                          'your "(Personal Team)" in Team, quit Xcode, then run this again.')
    try:
        team = normalize_team(team)
    except ConfigError:
        raise ConfigError(f'Xcode wrote "{team}" as the team, which is not a team ID.') from None
    if unexpected:
        shown = '\n    '.join(unexpected[:6])
        raise ConfigError(
            f'The project file has other changes besides the team ({team}), so it was not '
            f'restored automatically:\n    {shown}\n'
            f'Look at them with: git diff {PROJECT}\n'
            f'If you did not mean to make them, undo them with: git checkout -- {PROJECT}\n'
            f'Then save the team with: {SCRIPT} --team {team}')
    return team


def choose_detected_team():
    """(team or None, message for the person)."""
    teams = xcode_teams()
    if len(teams) == 1:
        return teams[0]['id'], f'Using the team Xcode knows: {describe(teams[0])}.'
    if not teams:
        return None, ('No Apple team found in Xcode yet. Open Xcode > Settings > Apple Accounts, '
                      'sign in with your Apple Account, close Settings, then run '
                      f'"{SCRIPT}" again. (If your team still is not found, see '
                      '--adopt-xcode-team in docs/ios.md.)')
    listed = '\n  '.join(describe(t) for t in teams)
    return None, ('Xcode knows several teams:\n  ' + listed +
                  f'\nChoose one and run: {SCRIPT} --team TEAMID')


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog=SCRIPT,
        description='Write ios/Config/Captura.local.xcconfig (git-ignored) for your own '
                    'Captura iOS build. No network; nothing secret is printed.')
    parser.add_argument('--bundle-id', help='unique to you, e.g. com.yourname.captura')
    parser.add_argument('--google-client-id', help='Client ID of your Google "iOS" OAuth client')
    parser.add_argument('--hosted-domain', default='',
                        help='optional Google Workspace domain, e.g. yourcompany.com')
    parser.add_argument('--team', help='Apple team ID (10 characters); detected from Xcode if omitted')
    parser.add_argument('--adopt-xcode-team', action='store_true',
                        help='take the team you picked in Xcode\'s Signing menu, save it here '
                             'and undo that change to the tracked project file')
    parser.add_argument('--force', action='store_true',
                        help='replace an existing Captura.local.xcconfig')
    args = parser.parse_args(argv)
    if bool(args.bundle_id) != bool(args.google_client_id):
        parser.error('--bundle-id and --google-client-id go together')
    if args.team and args.adopt_xcode_team:
        parser.error('use either --team or --adopt-xcode-team')
    return args


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    root = ROOT
    local = root / LOCAL
    try:
        team_note = None
        adopted = False
        if args.team:
            team = normalize_team(args.team)
        elif args.adopt_xcode_team:
            team = adopt_from_project(root)
            adopted = True
            team_note = f'Using the team you picked in Xcode: {team}.'
        else:
            team = None

        if args.bundle_id:
            if local.exists() and not args.force:
                raise ConfigError(f'{LOCAL} already exists. Keep it, or replace it by running the '
                                  'same command with --force.')
            bundle = normalize_bundle_id(args.bundle_id)
            client = normalize_client_id(args.google_client_id)
            domain = normalize_hosted_domain(args.hosted_domain)
            if team is None:
                team, team_note = choose_detected_team()
            write_atomically(local, render_xcconfig(bundle, team or '', client, domain))
            print(f'Wrote {LOCAL}:')
            print(f'  bundle ID       {bundle}')
            print(f'  Google client   {client}')
            print(f'  URL scheme      {reversed_client_id(client)}')
            print(f'  Workspace       {domain or "(any Google account)"}')
            print(f'  Apple team      {team or "(not set yet)"}')
        else:
            if not local.exists():
                raise ConfigError(
                    f'{LOCAL} does not exist yet. Create it first:\n'
                    f'  {SCRIPT} --bundle-id com.yourname.captura '
                    '--google-client-id YOUR-CLIENT-ID.apps.googleusercontent.com')
            text = local.read_text(encoding='utf-8')
            current, _ = read_xcconfig(local)
            existing = current.get(KEY_TEAM, '')
            if team is None:
                if existing and not args.force:
                    print(f'{LOCAL} already has team {existing}. Nothing to change.')
                    print('Next: python3 ios/scripts/check.py')
                    return 0
                team, team_note = choose_detected_team()
            if team is None:
                print(team_note, file=sys.stderr)
                return 1
            if team != existing:
                write_atomically(local, set_team_in_text(text, team))
            print(f'Saved Apple team {team} in {LOCAL}'
                  + (f' (was {existing}).' if existing and existing != team else '.'))

        if team_note:
            print(team_note)
        if adopted:
            if restore_project(root):
                print(f'Restored {PROJECT} to the downloaded version, so "git pull" keeps working.')
            else:
                print(f'Could not restore {PROJECT}. Run: git checkout -- {PROJECT}', file=sys.stderr)
                return 1
        if not team:
            return 0
        print('Next: python3 ios/scripts/check.py')
        return 0
    except ConfigError as error:
        print(f'Not changed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
