#!/usr/bin/env python3
"""Write ios/Config/Captura.local.xcconfig, the personal settings of a Captura iOS build.

Python 3 standard library only. No network or downloads of its own (with --from, the
password manager's CLI may go online to read the item). An iOS OAuth client ID and an
Apple team ID are identifiers, not secrets; nothing secret is written or printed.

    python3 ios/scripts/configure.py --bundle-id YOUR-BUNDLE-ID   # check it; writes nothing
    python3 ios/scripts/configure.py --bundle-id YOUR-BUNDLE-ID \\
        --google-client-id PASTE-THE-IOS-CLIENT-ID [--hosted-domain YOUR-WORKSPACE-DOMAIN]
    python3 ios/scripts/configure.py                      # fill in the team after Xcode sign-in
    python3 ios/scripts/configure.py --team ABCDE12345    # set the team explicitly
    python3 ios/scripts/configure.py --adopt-xcode-team   # move a team picked in Xcode here
    python3 ios/scripts/configure.py --from "op://Vault/Item"  # read the values from an item

--from reads the fields ios_client_id, bundle_id and (optional) hosted_domain from a
1Password item (op://Vault/Item) or a macOS Keychain service (keychain://service, one
account per field); --field-map renames them. Flags given explicitly win over the item.
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
PROJECT_DIR = Path('ios/Captura.xcodeproj')
PROJECT = PROJECT_DIR / 'project.pbxproj'
SCRIPT = 'python3 ios/scripts/configure.py'
# The command as docs/ios.md step 4 shows it, placeholders included.
CREATE_COMMAND = f'{SCRIPT} --bundle-id com.yourname.captura --google-client-id PASTE-THE-IOS-CLIENT-ID'

KEY_BUNDLE = 'CAPTURA_BUNDLE_ID'
KEY_TEAM = 'CAPTURA_DEVELOPMENT_TEAM'
KEY_CLIENT = 'CAPTURA_GOOGLE_IOS_CLIENT_ID'
KEY_REVERSED = 'CAPTURA_GOOGLE_REVERSED_CLIENT_ID'
KEY_DOMAIN = 'CAPTURA_GOOGLE_HOSTED_DOMAIN'

CLIENT_SUFFIX = '.apps.googleusercontent.com'
REVERSED_PREFIX = 'com.googleusercontent.apps.'
TEAM_PATTERN = re.compile(r'[A-Z0-9]{10}')
PLACEHOLDER_TEAM = '$(CAPTURA_DEVELOPMENT_TEAM)'
# Stand-ins the guides and this script show. Accepting one would register an app ID that
# is not yours (a free account gets 10 per week) or make every Google sign-in fail.
PLACEHOLDER_WORDS = ('example', 'yourname', 'your-name', 'your_name', 'yourcompany', 'yourdomain',
                     'your-', 'paste')
GUIDE_BUNDLE_IDS = ('com.anagarcia.captura',)
# Fields read by --from, as {option: default field name in the item}.
FROM_FIELDS = {'bundle_id': 'bundle_id', 'google_client_id': 'ios_client_id', 'hosted_domain': 'hosted_domain'}
FIELD_MAP_KEYS = ('ios_client_id', 'bundle_id', 'hosted_domain')
BUNDLE_HINT = 'Use "com." + your own name + ".captura", in lowercase with no spaces or accents.'


class ConfigError(Exception):
    """A value or state the person has to fix; the message says how."""

    prefix = 'Not changed'


class AlreadyConfigured(ConfigError):
    """The settings file exists and the person did not ask to replace it."""

    prefix = 'Already configured'


def _clean(value):
    return (value or '').strip().strip('"\'').strip()


def _placeholder(value):
    return any(word in value.lower() for word in PLACEHOLDER_WORDS)


def normalize_bundle_id(value):
    """Returns the bundle ID. It must already be lowercase: the Google admin enters exactly
    this value in the iOS client, so the script never changes it behind their back."""
    raw = _clean(value)
    bundle = raw.lower()
    if not bundle:
        raise ConfigError('The bundle ID is empty. ' + BUNDLE_HINT)
    if _placeholder(bundle):
        raise ConfigError(f'"{raw}" is an example from the guide, not your own bundle ID. ' + BUNDLE_HINT)
    if bundle in GUIDE_BUNDLE_IDS:
        raise ConfigError(f'"{raw}" is the guide\'s example. ' + BUNDLE_HINT +
                          ' If that really is your name, add your initials or second surname.')
    if (len(bundle) > 155 or '..' in bundle
            or not re.fullmatch(r'[a-z0-9-]+(\.[a-z0-9-]+)+', bundle)):
        raise ConfigError(f'"{raw}" is not a valid bundle ID. ' + BUNDLE_HINT)
    if raw != bundle:
        raise ConfigError(f'"{raw}" has capital letters; use {bundle}. Give the Google admin exactly '
                          'that lowercase value.')
    return bundle


def normalize_client_id(value):
    """Returns the iOS client ID. Accepts the reversed form (the "iOS URL scheme")."""
    client = _clean(value)
    if client.lower().startswith(REVERSED_PREFIX):
        client = client[len(REVERSED_PREFIX):] + CLIENT_SUFFIX
    if not client:
        raise ConfigError('The Google client ID is empty. Copy the Client ID of the iOS '
                          'OAuth client from Google Cloud.')
    if _placeholder(client):
        raise ConfigError(f'"{client}" is the placeholder from the guide. Put the Client ID of your '
                          f'own iOS OAuth client there (it ends in {CLIENT_SUFFIX}).')
    if not client.lower().endswith(CLIENT_SUFFIX):
        raise ConfigError(f'"{client}" is not a Google client ID: it must end in {CLIENT_SUFFIX}. '
                          'Copy the Client ID of the iOS OAuth client.')
    prefix = client[:-len(CLIENT_SUFFIX)]
    if not re.fullmatch(r'[0-9]+-[A-Za-z0-9_-]+', prefix):
        raise ConfigError(f'"{client}" is not a Google client ID. It starts with the project '
                          f'number, a hyphen and letters and digits, and ends in {CLIENT_SUFFIX}.')
    number = prefix.split('-', 1)[0]
    # Made-up project numbers (000000000000, 1234..., 123456789012) only appear in examples.
    if len(set(number)) == 1 or (len(number) >= 4 and '12345678901234567890'.startswith(number)):
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
    if _placeholder(domain):
        raise ConfigError(f'"{domain}" is an example from the guide. Leave --hosted-domain out, or use '
                          'your Google Workspace domain: the part after @ in your work address.')
    labels = domain.split('.')
    if len(labels) < 2 or not all(re.fullmatch(r'[a-z0-9]([a-z0-9-]*[a-z0-9])?', l) for l in labels):
        raise ConfigError(f'"{domain}" is not a domain. Use only your Google Workspace domain (the part '
                          'after @ in your work address), without @ or https://.')
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


# Stamps Xcode writes into the project and the shared scheme when it opens the project or
# when someone accepts "Update to recommended settings". Undoing them is harmless: Xcode
# only offers the update again.
UPGRADE_STAMP = re.compile(r'(LastUpgradeCheck|LastSwiftUpdateCheck)\s*=\s*\d+;'
                           r'|LastUpgradeVersion\s*=\s*"\d+"')


def project_team(root):
    """Team that Xcode's Signing menu wrote into the tracked project files.

    Looks at every tracked file in ios/Captura.xcodeproj (project and shared scheme).
    Returns (team, unexpected_lines, staged, upgrade_lines). `upgrade_lines` are only
    Xcode's upgrade-check stamps, safe to undo. Raises ConfigError when Git cannot tell.
    """
    staged = run(['git', 'diff', '--cached', '--quiet', '--', str(PROJECT_DIR)], cwd=root)
    diff = run(['git', 'diff', '--no-color', '--no-ext-diff', '-U0', '--', str(PROJECT_DIR)], cwd=root)
    if staged is None or diff is None or diff.returncode != 0 or staged.returncode not in (0, 1):
        raise ConfigError('Git could not compare the Xcode project with the downloaded version. '
                          'Run this from a folder created with "git clone", and pass the team '
                          'with --team instead.')
    teams, unexpected, upgrade = [], [], []
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
        if UPGRADE_STAMP.fullmatch(body):
            upgrade.append(line)
            continue
        unexpected.append(line)
    found = sorted(set(teams))
    if len(found) > 1:
        raise ConfigError('Xcode wrote more than one team into the project (' + ', '.join(found) +
                          '). Pick one and pass it with --team.')
    return (found[0] if found else None), unexpected, staged.returncode == 1, upgrade


def restore_project(root):
    result = run(['git', 'checkout', '--', str(PROJECT_DIR)], cwd=root)
    check = run(['git', 'diff', '--quiet', '--', str(PROJECT_DIR)], cwd=root)
    return result is not None and result.returncode == 0 and check is not None and check.returncode == 0


def adopt_from_project(root):
    """Reads the team written by Xcode; does not touch any file yet."""
    if xcode_is_running():
        raise ConfigError('Xcode is open. Quit Xcode first (Xcode > Quit Xcode), so it cannot '
                          'write the team back into the project, then run this again.')
    team, unexpected, staged, _ = project_team(root)
    if staged:
        raise ConfigError(f'{PROJECT_DIR} has changes staged in Git. Unstage them first '
                          f'("git restore --staged {PROJECT_DIR}"), then run this again.')
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
            f'The project has other changes besides the team ({team}), so it was not '
            f'restored automatically:\n    {shown}\n'
            'They usually come from Xcode\'s "Update to recommended settings". Undo them '
            '(this also takes the team out of the project). Keep them only if you edited '
            'the project on purpose:\n'
            f'  git checkout -- {PROJECT_DIR}\n'
            f'Then save the team in your settings:\n'
            f'  {SCRIPT} --team {team}')
    return team


def choose_detected_team():
    """(team or None, message for the person)."""
    teams = xcode_teams()
    if len(teams) == 1:
        return teams[0]['id'], f'Using the team Xcode knows: {describe(teams[0])}.'
    if not teams:
        return None, ('No Apple team found in Xcode yet. Open Xcode > Settings > Apple Accounts, '
                      'sign in with your Apple Account, close Settings, then run '
                      f'"{SCRIPT}" again. If it still finds none, carry on with docs/ios.md: '
                      'run step 5 (python3 ios/scripts/check.py), then step 6 (Open the project '
                      'and check signing) sets the team.')
    listed = '\n  '.join(describe(t) for t in teams)
    return None, ('Xcode knows several teams:\n  ' + listed +
                  f'\nChoose one and run: {SCRIPT} --team TEAMID')


def saved_team(local):
    """The valid team already in the settings file, or None."""
    if not local.exists():
        return None
    try:
        return normalize_team(read_xcconfig(local)[0].get(KEY_TEAM, ''))
    except ConfigError:
        return None


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog=SCRIPT,
        description='Write ios/Config/Captura.local.xcconfig (git-ignored) for your own '
                    'Captura iOS build. No network; nothing secret is printed.')
    parser.add_argument('--bundle-id', help='unique to you: "com." + your name + ".captura", lowercase. '
                                            'Alone, it only checks the value and writes nothing')
    parser.add_argument('--google-client-id', help='Client ID of your Google "iOS" OAuth client')
    parser.add_argument('--hosted-domain', default=None,
                        help='optional Google Workspace domain (the part after @ in your work address)')
    parser.add_argument('--team', help='Apple team ID (10 characters); detected from Xcode if omitted')
    parser.add_argument('--adopt-xcode-team', action='store_true',
                        help='take the team you picked in Xcode\'s Signing menu, save it here '
                             'and undo that change to the tracked project file')
    parser.add_argument('--force', action='store_true',
                        help='replace an existing Captura.local.xcconfig (the Apple team saved '
                             'in it is kept unless you pass --team)')
    parser.add_argument('--from', dest='source', metavar='REF',
                        help='read ios_client_id, bundle_id and optional hosted_domain from a 1Password '
                             'item (op://Vault/Item) or a Keychain service (keychain://service); '
                             'flags given explicitly win')
    parser.add_argument('--field-map', action='append', metavar='KEY=FIELD',
                        help='field names in the item when they differ from the defaults, e.g. '
                             'ios_client_id="iOS client ID" (keys: ' + ', '.join(FIELD_MAP_KEYS) + ')')
    args = parser.parse_args(argv)
    if args.field_map and not args.source:
        parser.error('--field-map needs --from')
    if not args.source:
        problem = combination_problem(args)
        if problem:
            parser.error(problem)
    return args


def combination_problem(args):
    """Options that cannot go together, once every value is known."""
    if args.google_client_id and not args.bundle_id:
        return '--google-client-id needs --bundle-id too'
    if args.bundle_id and not args.google_client_id and (args.team or args.adopt_xcode_team or args.force):
        return ('--bundle-id without --google-client-id only checks the bundle ID; '
                'run --team, --adopt-xcode-team or --force on their own')
    if args.team and args.adopt_xcode_team:
        return 'use either --team or --adopt-xcode-team'
    return None


def fill_from_source(args):
    """Takes the values the person did not pass from the item in --from. These are
    identifiers, not secrets, so they are shown and validated exactly like flags."""
    # Imported only here: every other use of this script works without scripts/.
    sys.path.insert(0, str(ROOT / 'scripts'))
    try:
        import secret_refs
    except ImportError:
        raise ConfigError('--from needs scripts/secret_refs.py, which this copy lacks. Update it with '
                          '"git pull", or pass the values with --bundle-id and --google-client-id.') from None
    try:
        names = secret_refs.parse_field_map(args.field_map, FIELD_MAP_KEYS)
        labels = {option: names.get('ios_client_id' if option == 'google_client_id' else option, default)
                  for option, default in FROM_FIELDS.items()}
        wanted = [labels[option] for option in FROM_FIELDS if getattr(args, option) is None]
        found = secret_refs.resolve_fields(args.source, wanted) if wanted else {}
    except secret_refs.SecretRefError as error:
        raise ConfigError(str(error)) from None
    taken = []
    for option, label in labels.items():
        if getattr(args, option) is None and label in found:
            setattr(args, option, found[label].strip())
            taken.append(label)
    if args.bundle_id is None and args.google_client_id is None:
        raise ConfigError(f'{args.source} has neither a "{labels["bundle_id"]}" nor an '
                          f'"{labels["google_client_id"]}" field. Check the field names in the item, or name '
                          'them with --field-map.')
    if args.google_client_id and not args.bundle_id:
        raise ConfigError(f'{args.source} has no "{labels["bundle_id"]}" field. Pass your bundle ID with '
                          '--bundle-id, or ask the admin to add that field to the item.')
    problem = combination_problem(args)
    if problem:
        raise ConfigError(problem + '.')
    return taken


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    root = ROOT
    local = root / LOCAL
    try:
        if args.source:
            taken = fill_from_source(args)
            print(f'Read {", ".join(taken) or "no fields"} from {args.source}.')
        if args.hosted_domain is None:
            args.hosted_domain = ''
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

        if args.bundle_id and not args.google_client_id:
            # Before the admin has made the iOS client: check the value they need.
            bundle = normalize_bundle_id(args.bundle_id)
            normalize_hosted_domain(args.hosted_domain)
            print(f'Bundle ID {bundle} looks right. Nothing was written.')
            print(f'Send the Google admin exactly this value: {bundle}')
            print('When the admin sends you the iOS client ID, save your settings with:')
            print(f'Next: {SCRIPT} --bundle-id {bundle} --google-client-id PASTE-THE-IOS-CLIENT-ID')
            return 0
        if args.bundle_id:
            if local.exists() and not args.force:
                raise AlreadyConfigured(f'{LOCAL} exists from an earlier run. Keep it, or replace it '
                                        'by running the same command with --force.')
            bundle = normalize_bundle_id(args.bundle_id)
            client = normalize_client_id(args.google_client_id)
            domain = normalize_hosted_domain(args.hosted_domain)
            if team is None:
                kept = saved_team(local)
                if kept:
                    team, team_note = kept, (f'Kept the Apple team saved earlier: {kept}. '
                                             'To use another one, add --team TEAMID.')
                else:
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
                    f'{LOCAL} does not exist yet. Create it first (docs/ios.md step 4):\n'
                    f'  {CREATE_COMMAND}')
            text = local.read_text(encoding='utf-8')
            current, _ = read_xcconfig(local)
            existing = current.get(KEY_TEAM, '')
            if team is None:
                if existing and not args.force:
                    print(f'{LOCAL} already has team {existing}. Nothing to change.')
                    print('Next: python3 ios/scripts/check.py')
                    return 0
                team, team_note = choose_detected_team()
            if team is None and existing:
                print(team_note)
                print(f'Kept the Apple team saved earlier: {existing}.')
                print('Next: python3 ios/scripts/check.py')
                return 0
            if team is None:
                # Same outcome as the first run without a team: expected, not an error.
                print(team_note)
                return 0
            if team != existing:
                write_atomically(local, set_team_in_text(text, team))
            print(f'Saved Apple team {team} in {LOCAL}'
                  + (f' (was {existing}).' if existing and existing != team else '.'))

        if team_note:
            print(team_note)
        if adopted:
            if restore_project(root):
                print(f'Restored {PROJECT_DIR} to the downloaded version, so "git pull" keeps working.')
            else:
                print(f'Could not restore {PROJECT_DIR}. Undo the change with:', file=sys.stderr)
                print(f'Next: git checkout -- {PROJECT_DIR}', file=sys.stderr)
                return 1
        if not team:
            return 0
        print('Next: python3 ios/scripts/check.py')
        return 0
    except ConfigError as error:
        print(f'{error.prefix}: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
