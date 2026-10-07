#!/usr/bin/env python3
"""Check that this Mac is ready to install Captura on an iPhone. Read-only, no network.

    python3 ios/scripts/check.py

Each line says what was found; anything marked FAIL comes with the next step. A `Next:`
line holds either one command to paste or a sentence, never both. The exit status is 1
while something blocks installing on the iPhone, 0 otherwise.
"""
import argparse
import json
from pathlib import Path
import platform
import re
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import configure  # noqa: E402  (same folder)
from configure import ConfigError, run  # noqa: E402

OK, WARN, FAIL, INFO = 'ok', 'warn', 'FAIL', 'info'
XCODE_PATH = '/Applications/Xcode.app/Contents/Developer'
CONFIGURE = configure.SCRIPT
CREATE_LOCAL = configure.CREATE_COMMAND
NO_TEAM = 'not set and no team found in Xcode'
STEP_6 = 'step 6 of docs/ios.md (Open the project and check signing)'


class Report:
    def __init__(self):
        self.lines = []

    def add(self, status, title, detail='', next_step='', note=''):
        """`next_step` is one command or one sentence; `note` is prose shown above it."""
        self.lines.append((status, title, detail, next_step, note))

    @property
    def blocking(self):
        return [line for line in self.lines if line[0] == FAIL]

    def render(self):
        out = ['Captura iOS check (read-only, no network)', '']
        for status, title, detail, next_step, note in self.lines:
            out.append(f'  {status:<5} {title}' + (f': {detail}' if detail else ''))
            if note:
                out.append('        ' + note)
            if next_step:
                out.append('        Next: ' + next_step)
        out.append('')
        if [line[:2] for line in self.blocking] == [(FAIL, 'Apple team')] and self.blocking[0][2] == NO_TEAM:
            # Expected before step 6: Xcode only knows the team once it has been picked there.
            out.append('Only the Apple team is missing. That is expected if configure.py found no '
                       f'team: continue with {STEP_6}, then run this check again.')
        elif self.blocking:
            count = len(self.blocking)
            out.append(f'{count} problem{"s" if count > 1 else ""} block{"" if count > 1 else "s"} '
                       'installing on the iPhone. Fix the first FAIL above, then run this check again.')
        else:
            out.append('Ready. Open ios/Captura.xcodeproj in Xcode, pick your iPhone at the top '
                       'and press Run (see docs/ios.md).')
        return '\n'.join(out)


def text(result):
    if result is None:
        return ''
    return (result.stdout or b'').decode('utf-8', 'replace') + (result.stderr or b'').decode('utf-8', 'replace')


def check_mac(report):
    if platform.system() != 'Darwin':
        report.add(FAIL, 'Mac', 'this is not macOS', 'Xcode and the iPhone install need a Mac.')
        return
    version = platform.mac_ver()[0] or '?'
    machine = platform.machine()
    parts = [int(p) for p in re.findall(r'\d+', version)[:2]] + [0, 0]
    if machine != 'arm64':
        report.add(WARN, 'Mac', f'{machine}, macOS {version}',
                   'Xcode 27 runs only on Apple silicon (M1 or newer).')
    elif tuple(parts[:2]) < (26, 6):
        report.add(WARN, 'Mac', f'Apple silicon, macOS {version}',
                   'Xcode 27 needs macOS 26.6 or later: System Settings > General > Software Update '
                   '(Configuración del Sistema > General > Actualización de software).')
    else:
        report.add(OK, 'Mac', f'Apple silicon, macOS {version}')


def check_xcode(report):
    """Returns True when xcodebuild works."""
    selected = run(['xcode-select', '-p'], timeout=20)
    path = text(selected).strip() if selected is not None and selected.returncode == 0 else ''
    version = run(['xcodebuild', '-version'], timeout=60)
    output = text(version)
    if version is None or version.returncode != 0:
        if 'license' in output.lower():
            report.add(FAIL, 'Xcode', 'the Xcode license has not been accepted',
                       'Open Xcode once and accept the license.')
        elif path and 'CommandLineTools' in path and Path(XCODE_PATH).is_dir():
            report.add(FAIL, 'Xcode', 'installed, but the command line uses the Command Line Tools',
                       f'sudo xcode-select --switch {XCODE_PATH}',
                       note='This asks for your Mac password.')
        else:
            report.add(FAIL, 'Xcode', 'not found',
                       'Install Xcode from the Mac App Store (free, about 3 GB), open it once, '
                       'then run this check again.')
        return False
    match = re.search(r'Xcode\s+(\d+)(?:\.(\d+))?(?:\.(\d+))?', output)
    if not match:
        report.add(WARN, 'Xcode', 'could not read the version', 'Open Xcode once, then run this check again.')
        return True
    major = int(match.group(1))
    label = '.'.join(g for g in match.groups() if g is not None)
    if major < 16:
        report.add(FAIL, 'Xcode', f'{label} is too old for this project',
                   'Update Xcode from the Mac App Store.')
        return False
    if major < 27:
        report.add(WARN, 'Xcode', f'{label} ({path or "path unknown"})',
                   'These steps were written for Xcode 27. If your iPhone runs a newer iOS than '
                   'this Xcode supports, update Xcode from the Mac App Store.')
    else:
        report.add(OK, 'Xcode', f'{label} ({path or "path unknown"})')
    first = run(['xcodebuild', '-checkFirstLaunchStatus'], timeout=60)
    if first is not None and first.returncode != 0:
        report.add(WARN, 'Xcode first launch', 'Xcode has not finished installing its components',
                   'Open Xcode and let it finish.')
    return True


def check_platform(report):
    """Returns True when an iOS device SDK is installed."""
    sdks = run(['xcodebuild', '-showsdks'], timeout=60)
    found = re.findall(r'-sdk\s+iphoneos(\d+(?:\.\d+)*)', text(sdks))
    if not found:
        report.add(FAIL, 'iOS platform', 'not installed',
                   'Open Xcode > Settings > Components and click Get next to iOS (several GB).')
        return False
    report.add(OK, 'iOS platform', 'iOS SDK ' + ', '.join(sorted(set(found))))
    return True


def check_local_config(report, root):
    """Returns (values dict or None, team or '')."""
    local = root / configure.LOCAL
    if not local.is_file():
        report.add(FAIL, 'Your settings', f'{configure.LOCAL} does not exist', CREATE_LOCAL,
                   note='Put your bundle ID and the iOS client ID in place of the examples (docs/ios.md step 4).')
        return None, ''
    values, truncated = configure.read_xcconfig(local)
    problems = []
    if truncated:
        problems.append('a value contains "//", which cuts it short: ' + ', '.join(truncated))
    try:
        bundle = configure.normalize_bundle_id(values.get(configure.KEY_BUNDLE, ''))
    except ConfigError as error:
        problems.append(f'{configure.KEY_BUNDLE}: {error}')
        bundle = None
    try:
        client = configure.normalize_client_id(values.get(configure.KEY_CLIENT, ''))
        reversed_id = values.get(configure.KEY_REVERSED, '')
        if reversed_id and reversed_id != configure.reversed_client_id(client):
            problems.append(f'{configure.KEY_REVERSED} must be {configure.reversed_client_id(client)} '
                            'or empty')
    except ConfigError as error:
        problems.append(f'{configure.KEY_CLIENT}: {error}')
        client = None
    try:
        domain = configure.normalize_hosted_domain(values.get(configure.KEY_DOMAIN, ''))
    except ConfigError as error:
        problems.append(f'{configure.KEY_DOMAIN}: {error}')
        domain = None
    if problems:
        report.add(FAIL, 'Your settings', '; '.join(problems), CREATE_LOCAL + ' --force',
                   note='Save your settings again with --force, with your own values in place of the examples.')
        return None, ''
    report.add(OK, 'Your settings', f'bundle ID {bundle}, Google client {client}'
               + (f', Workspace {domain}' if domain else ''))
    ignored = run(['git', 'check-ignore', '-q', str(configure.LOCAL)], cwd=root, timeout=20)
    if ignored is not None and ignored.returncode == 1:
        report.add(WARN, 'Git', f'{configure.LOCAL} is not ignored by Git',
                   'Do not commit it. Restore .gitignore from the repository.')
    values = dict(values, **{configure.KEY_BUNDLE: bundle})
    return values, values.get(configure.KEY_TEAM, '')


def check_team(report, root, team):
    try:
        project_team, unexpected, _, upgrade = configure.project_team(root)
    except ConfigError:
        project_team, unexpected, upgrade = None, [], []
    quit_first = 'Quit Xcode first (Xcode > Quit Xcode).'
    if team:
        try:
            team = configure.normalize_team(team)
        except ConfigError as error:
            report.add(FAIL, 'Apple team', str(error), f'{CONFIGURE} --team TEAMID')
            team = ''
        else:
            report.add(OK, 'Apple team', team)
            if project_team:
                report.add(WARN, 'Xcode project', 'Xcode wrote a team into the tracked project file',
                           f'{CONFIGURE} --adopt-xcode-team', note=quit_first)
    elif project_team:
        report.add(FAIL, 'Apple team', f'picked in Xcode ({project_team}) but not saved in your settings',
                   f'{CONFIGURE} --adopt-xcode-team', note=quit_first)
    else:
        teams = configure.xcode_teams()
        if len(teams) == 1:
            report.add(FAIL, 'Apple team', 'not saved yet; Xcode knows ' + configure.describe(teams[0]),
                       CONFIGURE)
        elif teams:
            report.add(FAIL, 'Apple team', 'not saved yet; Xcode knows several: '
                       + ', '.join(configure.describe(t) for t in teams),
                       f'{CONFIGURE} --team TEAMID', note='Put the team you want in place of TEAMID.')
        else:
            report.add(FAIL, 'Apple team', NO_TEAM, CONFIGURE,
                       note='Open Xcode > Settings > Apple Accounts and sign in, then run the command '
                            f'below. If it still finds none, continue with {STEP_6}; this clears '
                            'after configure.py --adopt-xcode-team.')
    if not project_team and (unexpected or upgrade):
        # Checked with or without a team: a leftover change can stop "git pull" at the weekly reinstall.
        report.add(WARN, 'Xcode project',
                   f'tracked files in {configure.PROJECT_DIR} have changes (for example from "Update to '
                   'recommended settings"); "git pull" can stop on them',
                   f'git checkout -- {configure.PROJECT_DIR}',
                   note='Unless you changed the project on purpose, quit Xcode and undo them.')
    return team


def check_build_settings(report, root, values, team):
    result = run(['xcodebuild', '-project', 'ios/Captura.xcodeproj', '-target', 'Captura',
                  '-configuration', 'Debug', '-showBuildSettings', '-sdk', 'iphoneos'],
                 cwd=root, timeout=180)
    settings = {}
    for line in text(result).splitlines():
        match = re.fullmatch(r'\s*([A-Z_][A-Z0-9_]*) = (.*)', line)
        if match:
            settings[match.group(1)] = match.group(2).strip()
    if result is None or result.returncode != 0 or not settings:
        report.add(WARN, 'Xcode reads your settings', 'xcodebuild could not list the build settings',
                   'Open ios/Captura.xcodeproj in Xcode once; if it shows an error, see docs/ios.md.')
        return
    bundle = settings.get('PRODUCT_BUNDLE_IDENTIFIER', '')
    resolved_team = settings.get('DEVELOPMENT_TEAM', '')
    if bundle != values[configure.KEY_BUNDLE]:
        report.add(FAIL, 'Xcode reads your settings', f'Xcode sees bundle ID "{bundle}"',
                   f'Make sure the file is exactly {configure.LOCAL} (same folder as '
                   'Captura.base.xcconfig), then run this check again.')
    elif team and resolved_team != team:
        report.add(FAIL, 'Xcode reads your settings', f'Xcode uses team "{resolved_team}", not {team}',
                   f'{CONFIGURE} --adopt-xcode-team', note='Quit Xcode first (Xcode > Quit Xcode).')
    else:
        report.add(OK, 'Xcode reads your settings', f'bundle ID {bundle}'
                   + (f', team {resolved_team}' if resolved_team else ''))


def check_devices(report):
    """Informational: what Xcode sees over the cable. Never blocking."""
    with tempfile.TemporaryDirectory(prefix='captura-check-') as scratch:
        output = Path(scratch) / 'devices.json'
        result = run(['xcrun', 'devicectl', 'list', 'devices', '--json-output', str(output)], timeout=90)
        try:
            devices = json.loads(output.read_text())['result']['devices']
        except Exception:
            devices = None
    if result is None or devices is None:
        report.add(INFO, 'iPhone', 'could not list devices (needs Xcode 15 or later)')
        return
    phones = []
    for device in devices:
        hardware = device.get('hardwareProperties') or {}
        props = device.get('deviceProperties') or {}
        connection = device.get('connectionProperties') or {}
        if str(hardware.get('platform', 'iOS')).lower() not in ('ios', 'iphoneos'):
            continue
        phones.append((props.get('name') or 'iPhone',
                       hardware.get('marketingName') or hardware.get('productType') or '',
                       props.get('osVersionNumber') or '',
                       connection.get('pairingState') or '',
                       props.get('developerModeStatus') or '',
                       connection.get('transportType') or ''))
    if not phones:
        report.add(INFO, 'iPhone', 'none seen yet',
                   'Connect the iPhone with a cable, unlock it and tap "Confiar" (Trust).')
        return
    for name, model, ios, pairing, developer, transport in phones:
        detail = ', '.join(x for x in (model, f'iOS {ios}' if ios else '',
                                       f'pairing {pairing}' if pairing else '',
                                       f'Developer Mode {developer}' if developer else '',
                                       'connected' if transport else 'not connected now') if x)
        next_step = ''
        if pairing and pairing != 'paired':
            next_step = 'Unlock the iPhone and tap "Confiar" (Trust) when it asks about this Mac.'
        elif developer and developer != 'enabled':
            next_step = ('On the iPhone: Configuración > Privacidad y seguridad > Modo de desarrollador, '
                         'turn it on and restart.')
        report.add(INFO if not next_step else WARN, f'iPhone "{name}"', detail, next_step)


def main(argv=None):
    argparse.ArgumentParser(
        prog='python3 ios/scripts/check.py',
        description='Check that this Mac is ready to install Captura on an iPhone: Xcode, the '
                    'iOS platform, your settings file, the Apple team, whether Xcode reads your '
                    'settings, and any iPhone connected by cable. Read-only; never goes online. '
                    'Exit status 1 while something blocks installing.',
        epilog='See docs/ios.md, step 5.').parse_args(sys.argv[1:] if argv is None else argv)
    root = configure.ROOT
    report = Report()
    check_mac(report)
    xcode_ok = check_xcode(report)
    sdk_ok = check_platform(report) if xcode_ok else False
    values, team = check_local_config(report, root)
    if values is not None:
        team = check_team(report, root, team)
        if xcode_ok and sdk_ok:
            check_build_settings(report, root, values, team)
    if xcode_ok:
        check_devices(report)
    print(report.render())
    return 1 if report.blocking else 0


if __name__ == '__main__':
    raise SystemExit(main())
