"""ios/scripts/configure.py and check.py against a temporary Git copy of the project.

Xcode, `defaults`, `pgrep` and `xcrun` are fakes (tests/fake_tools.py); Git is real but
isolated from the user's configuration. No network, no real Apple or Google account.
"""
import contextlib
import io
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'ios/scripts'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import check  # noqa: E402
import configure  # noqa: E402
import fake_tools  # noqa: E402

CLIENT = '123456789012-fictionalclientabc.apps.googleusercontent.com'
REVERSED = 'com.googleusercontent.apps.123456789012-fictionalclientabc'
BUNDLE = 'org.fictional.captura'
TEAM = 'TEAMFAKE01'
OTHER_TEAM = 'TEAMFAKE02'
PROJECT = 'ios/Captura.xcodeproj/project.pbxproj'
LOCAL = 'ios/Config/Captura.local.xcconfig'
GIT = shutil.which('git')


def personal_teams(*teams):
    """Xcode preferences shaped like `IDEProvisioningTeams`: account -> list of teams."""
    return {'IDEProvisioningTeams': {'person@fictional.test': [
        {'teamID': team, 'teamName': f'Fictional Person {i} (Personal Team)',
         'isFreeProvisioningTeam': True, 'teamType': 'Individual'} for i, team in enumerate(teams)]}}


@unittest.skipUnless(GIT, 'git is required')
class Sandbox(unittest.TestCase):
    """A temporary clone-like copy of the iOS project plus fake tools on PATH."""

    @classmethod
    def setUpClass(cls):
        cls._bin = tempfile.TemporaryDirectory()

    @classmethod
    def tearDownClass(cls):
        cls._bin.cleanup()

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        tmp = Path(self._tmp.name)
        self.repo = tmp / 'repo'
        for rel in (PROJECT, 'ios/Config/Captura.base.xcconfig', 'ios/scripts/configure.py',
                    'ios/scripts/check.py'):
            (self.repo / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, self.repo / rel)
        (self.repo / '.gitignore').write_text(LOCAL + '\n')
        self.bin = Path(self._bin.name)
        self.prefs = tmp / 'xcode-prefs.plist'
        self.env = dict(os.environ, HOME=str(tmp), PATH=f'{self.bin}:/usr/bin:/bin',
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1',
                        GIT_AUTHOR_NAME='Fictional', GIT_AUTHOR_EMAIL='fictional@fictional.test',
                        GIT_COMMITTER_NAME='Fictional', GIT_COMMITTER_EMAIL='fictional@fictional.test')
        self.git('init', '-q')
        self.git('add', '-A')
        self.git('commit', '-q', '-m', 'fixture')
        self.tools()

    def tearDown(self):
        self._tmp.cleanup()

    def git(self, *args):
        return subprocess.run([GIT, *args], cwd=self.repo, env=self.env, capture_output=True,
                              text=True, check=True).stdout

    def tools(self, teams=None, xcode_running=False, extra=None):
        spec = {'pgrep': [{'match': ['Xcode'], 'rc': 0 if xcode_running else 1}]}
        if teams is not None:
            self.prefs.write_bytes(plistlib.dumps(teams))
            spec['defaults'] = [{'match': ['export', 'com.apple.dt.Xcode'], 'stdout': self.prefs.read_text()}]
        else:
            spec['defaults'] = [{'match': ['export'], 'rc': 1, 'stderr': 'Domain does not exist'}]
        spec.update(extra or {})
        fake_tools.install(self.bin, spec)

    def configure(self, *args):
        return subprocess.run([sys.executable, str(self.repo / 'ios/scripts/configure.py'), *args],
                              cwd=self.repo, env=self.env, capture_output=True, text=True)

    def local(self):
        return configure.read_xcconfig(self.repo / LOCAL)[0]

    def xcode_picks_team(self, team=TEAM, extra_change=False):
        """What Xcode's Signing & Capabilities > Team menu does to the tracked project."""
        path = self.repo / PROJECT
        text = path.read_text()
        text = text.replace('DEVELOPMENT_TEAM = "$(CAPTURA_DEVELOPMENT_TEAM)";', f'DEVELOPMENT_TEAM = {team};', 2)
        text = text.replace('CreatedOnToolsVersion = 26.1;\n\t\t\t\t\t};',
                            f'CreatedOnToolsVersion = 26.1;\n\t\t\t\t\t\tDevelopmentTeam = {team};\n\t\t\t\t\t}};', 1)
        if extra_change:
            text = text.replace('MARKETING_VERSION = 0.1.0;', 'MARKETING_VERSION = 0.2.0;', 1)
        path.write_text(text)

    def xcode_stamps_upgrade(self):
        """What a newer Xcode writes when it opens the project or applies recommended settings."""
        path = self.repo / PROJECT
        text = path.read_text()
        self.assertIn('LastUpgradeCheck = 2610;', text)
        path.write_text(text.replace('LastUpgradeCheck = 2610;', 'LastUpgradeCheck = 2700;')
                        .replace('LastSwiftUpdateCheck = 2610;', 'LastSwiftUpdateCheck = 2700;'))

    def project_is_clean(self):
        return self.git('status', '--porcelain', '--', PROJECT) == ''


class ConfigureTests(Sandbox):
    def test_writes_settings_and_detects_the_single_personal_team(self):
        self.tools(teams=personal_teams(TEAM))
        result = self.configure('--bundle-id', BUNDLE, '--google-client-id', CLIENT)
        self.assertEqual(result.returncode, 0, result.stderr)
        values = self.local()
        self.assertEqual(values['CAPTURA_BUNDLE_ID'], BUNDLE)
        self.assertEqual(values['CAPTURA_DEVELOPMENT_TEAM'], TEAM)
        self.assertEqual(values['CAPTURA_GOOGLE_IOS_CLIENT_ID'], CLIENT)
        self.assertEqual(values['CAPTURA_GOOGLE_REVERSED_CLIENT_ID'], REVERSED)
        self.assertEqual(values['CAPTURA_GOOGLE_HOSTED_DOMAIN'], '')
        for line in (self.repo / LOCAL).read_text().splitlines():
            if not line.startswith('//'):
                self.assertNotIn('//', line)
        self.assertEqual(self.git('check-ignore', LOCAL).strip(), LOCAL)
        self.assertTrue(self.project_is_clean())

    def test_accepts_the_reversed_id_and_a_workspace_domain(self):
        result = self.configure('--bundle-id', BUNDLE, '--google-client-id', REVERSED,
                                '--hosted-domain', '@Fictional-Company.TEST', '--team', TEAM.lower())
        self.assertEqual(result.returncode, 0, result.stderr)
        values = self.local()
        self.assertEqual(values['CAPTURA_GOOGLE_IOS_CLIENT_ID'], CLIENT)
        self.assertEqual(values['CAPTURA_GOOGLE_HOSTED_DOMAIN'], 'fictional-company.test')
        self.assertEqual(values['CAPTURA_DEVELOPMENT_TEAM'], TEAM)

    def test_rejects_examples_and_malformed_values_without_writing(self):
        cases = [
            ('--bundle-id', 'com.example.captura'),
            ('--bundle-id', 'captura'),
            ('--google-client-id', '000000000000-example.apps.googleusercontent.com'),
            ('--google-client-id', 'fictional-secret-looking-value'),
            ('--hosted-domain', 'https://fictional.test'),
            ('--team', 'ABC'),
        ]
        for flag, value in cases:
            with self.subTest(flag=flag, value=value):
                args = {'--bundle-id': BUNDLE, '--google-client-id': CLIENT}
                args[flag] = value
                result = self.configure(*[x for pair in args.items() for x in pair])
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn('Not changed', result.stderr)
                self.assertFalse((self.repo / LOCAL).exists())

    def test_refuses_to_overwrite_without_force(self):
        self.configure('--bundle-id', BUNDLE, '--google-client-id', CLIENT, '--team', TEAM)
        before = (self.repo / LOCAL).read_text()
        again = self.configure('--bundle-id', 'org.fictional.other', '--google-client-id', CLIENT)
        self.assertEqual(again.returncode, 1)
        self.assertIn('--force', again.stderr)
        # Its own prefix: the docs tell "Not changed" (a wrong value) apart from this case.
        self.assertTrue(again.stderr.startswith('Already configured:'), again.stderr)
        self.assertNotIn('Not changed', again.stderr)
        self.assertEqual((self.repo / LOCAL).read_text(), before)
        forced = self.configure('--bundle-id', 'org.fictional.other', '--google-client-id', CLIENT,
                                '--team', TEAM, '--force')
        self.assertEqual(forced.returncode, 0, forced.stderr)
        self.assertEqual(self.local()['CAPTURA_BUNDLE_ID'], 'org.fictional.other')

    def test_force_keeps_the_team_saved_earlier_when_xcode_lists_none(self):
        self.assertEqual(self.configure('--bundle-id', BUNDLE, '--google-client-id', CLIENT,
                                        '--team', TEAM).returncode, 0)
        forced = self.configure('--bundle-id', 'org.fictional.other', '--google-client-id', CLIENT,
                                '--force')
        self.assertEqual(forced.returncode, 0, forced.stderr)
        self.assertEqual(self.local()['CAPTURA_DEVELOPMENT_TEAM'], TEAM)
        self.assertEqual(self.local()['CAPTURA_BUNDLE_ID'], 'org.fictional.other')
        self.assertIn(f'Kept the Apple team saved earlier: {TEAM}', forced.stdout)
        self.assertNotIn('No Apple team found', forced.stdout + forced.stderr)

    def test_force_keeps_the_saved_team_over_a_detected_one_unless_team_is_given(self):
        self.configure('--bundle-id', BUNDLE, '--google-client-id', CLIENT, '--team', OTHER_TEAM)
        self.tools(teams=personal_teams(TEAM))
        self.configure('--bundle-id', BUNDLE, '--google-client-id', CLIENT, '--force')
        self.assertEqual(self.local()['CAPTURA_DEVELOPMENT_TEAM'], OTHER_TEAM)
        replaced = self.configure('--bundle-id', BUNDLE, '--google-client-id', CLIENT, '--force',
                                  '--team', TEAM)
        self.assertEqual(replaced.returncode, 0, replaced.stderr)
        self.assertEqual(self.local()['CAPTURA_DEVELOPMENT_TEAM'], TEAM)

    def test_bare_force_keeps_the_saved_team_when_xcode_lists_none(self):
        self.configure('--bundle-id', BUNDLE, '--google-client-id', CLIENT, '--team', TEAM)
        result = self.configure('--force')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.local()['CAPTURA_DEVELOPMENT_TEAM'], TEAM)
        self.assertIn(f'Kept the Apple team saved earlier: {TEAM}', result.stdout)

    def test_bundle_id_is_saved_in_lowercase(self):
        result = self.configure('--bundle-id', 'Org.Fictional.Captura', '--google-client-id', CLIENT,
                                '--team', TEAM)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.local()['CAPTURA_BUNDLE_ID'], BUNDLE)
        self.assertIn(f'lowercase: {BUNDLE}', result.stdout)

    def test_without_teams_it_writes_the_rest_and_explains_apple_accounts(self):
        result = self.configure('--bundle-id', BUNDLE, '--google-client-id', CLIENT)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.local()['CAPTURA_DEVELOPMENT_TEAM'], '')
        self.assertIn('Xcode > Settings > Apple Accounts', result.stdout)
        self.assertIn('step 6', result.stdout)
        later = self.configure()
        self.assertEqual(later.returncode, 1)
        self.tools(teams=personal_teams(TEAM))
        after_sign_in = self.configure()
        self.assertEqual(after_sign_in.returncode, 0, after_sign_in.stderr)
        self.assertEqual(self.local()['CAPTURA_DEVELOPMENT_TEAM'], TEAM)
        self.assertEqual(self.local()['CAPTURA_BUNDLE_ID'], BUNDLE)

    def test_several_teams_are_listed_and_need_an_explicit_choice(self):
        self.tools(teams=personal_teams(TEAM, OTHER_TEAM))
        result = self.configure('--bundle-id', BUNDLE, '--google-client-id', CLIENT)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(TEAM, result.stdout)
        self.assertIn(OTHER_TEAM, result.stdout)
        self.assertEqual(self.local()['CAPTURA_DEVELOPMENT_TEAM'], '')
        chosen = self.configure('--team', OTHER_TEAM)
        self.assertEqual(chosen.returncode, 0, chosen.stderr)
        self.assertEqual(self.local()['CAPTURA_DEVELOPMENT_TEAM'], OTHER_TEAM)
        self.assertEqual(self.local()['CAPTURA_GOOGLE_IOS_CLIENT_ID'], CLIENT)

    def test_team_only_update_needs_an_existing_file(self):
        result = self.configure('--team', TEAM)
        self.assertEqual(result.returncode, 1)
        self.assertIn('--bundle-id', result.stderr)

    def test_adopts_the_team_picked_in_xcode_and_restores_the_project(self):
        self.configure('--bundle-id', BUNDLE, '--google-client-id', CLIENT)
        self.xcode_picks_team()
        self.assertFalse(self.project_is_clean())
        result = self.configure('--adopt-xcode-team')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.local()['CAPTURA_DEVELOPMENT_TEAM'], TEAM)
        self.assertTrue(self.project_is_clean())

    def test_adopt_also_undoes_xcode_upgrade_stamps(self):
        self.configure('--bundle-id', BUNDLE, '--google-client-id', CLIENT)
        self.xcode_picks_team()
        self.xcode_stamps_upgrade()
        result = self.configure('--adopt-xcode-team')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.local()['CAPTURA_DEVELOPMENT_TEAM'], TEAM)
        self.assertTrue(self.project_is_clean())

    def test_adopt_refuses_other_project_changes_and_keeps_them(self):
        self.configure('--bundle-id', BUNDLE, '--google-client-id', CLIENT)
        self.xcode_picks_team(extra_change=True)
        result = self.configure('--adopt-xcode-team')
        self.assertEqual(result.returncode, 1)
        self.assertIn('MARKETING_VERSION', result.stderr)
        self.assertIn(f'git checkout -- {PROJECT}', result.stderr)
        self.assertIn('Update to recommended settings', result.stderr)
        self.assertIn(f'--team {TEAM}', result.stderr)
        self.assertFalse(self.project_is_clean())
        self.assertEqual(self.local()['CAPTURA_DEVELOPMENT_TEAM'], '')

    def test_adopt_refuses_while_xcode_is_open(self):
        self.configure('--bundle-id', BUNDLE, '--google-client-id', CLIENT)
        self.xcode_picks_team()
        self.tools(xcode_running=True)
        result = self.configure('--adopt-xcode-team')
        self.assertEqual(result.returncode, 1)
        self.assertIn('Quit Xcode', result.stderr)
        self.assertFalse(self.project_is_clean())

    def test_adopt_without_a_team_in_the_project_explains_the_signing_menu(self):
        self.configure('--bundle-id', BUNDLE, '--google-client-id', CLIENT)
        result = self.configure('--adopt-xcode-team')
        self.assertEqual(result.returncode, 1)
        self.assertIn('Signing & Capabilities', result.stderr)


class TeamDetectionTests(Sandbox):
    def detect(self, prefs):
        self.tools(teams=prefs)
        with mock.patch.dict(os.environ, self.env, clear=True):
            return configure.xcode_teams()

    def test_reads_teams_keyed_by_identifier(self):
        prefs = {'IDEProvisioningTeamByIdentifier': {'fictional-account-id': [
            {'teamID': TEAM, 'teamName': 'Fictional Person', 'isFreeProvisioningTeam': 1},
            {'teamID': OTHER_TEAM, 'teamName': 'Fictional Company', 'isFreeProvisioningTeam': 0}]},
            'UnrelatedKey': {'teamID': 'IGNOREME01'}}
        teams = self.detect(prefs)
        self.assertEqual([t['id'] for t in teams], [TEAM, OTHER_TEAM])
        self.assertTrue(teams[0]['free'])
        self.assertFalse(teams[1]['free'])

    def test_no_xcode_preferences_means_no_teams(self):
        self.tools()
        with mock.patch.dict(os.environ, self.env, clear=True):
            self.assertEqual(configure.xcode_teams(), [])


def xcode_tools(version='Xcode 27.0\nBuild version 27A0000\n', sdks=True, settings_team=TEAM,
                bundle=BUNDLE, devices=None, license_error=False):
    sdk_text = 'iOS SDKs:\n\tiOS 27.0 \t-sdk iphoneos27.0\n' if sdks else 'macOS SDKs:\n\t-sdk macosx27.0\n'
    settings = f'Build settings for action build and target Captura:\n    PRODUCT_BUNDLE_IDENTIFIER = {bundle}\n'
    if settings_team:
        settings += f'    DEVELOPMENT_TEAM = {settings_team}\n'
    version_rule = ({'match': ['-version'], 'rc': 69, 'stderr': 'You have not agreed to the Xcode license agreements.'}
                    if license_error else {'match': ['-version'], 'stdout': version})
    return {
        'xcode-select': [{'match': ['-p'], 'stdout': '/Applications/Xcode.app/Contents/Developer\n'}],
        'xcodebuild': [version_rule,
                       {'match': ['-checkFirstLaunchStatus'], 'rc': 0},
                       {'match': ['-showsdks'], 'stdout': sdk_text},
                       {'match': ['-showBuildSettings'], 'stdout': settings}],
        'xcrun': [{'match': ['devicectl', 'list', 'devices'],
                   'json_output': {'info': {'outcome': 'success'}, 'result': {'devices': devices or []}}}],
    }


def fictional_iphone(developer='enabled', pairing='paired'):
    return {'deviceProperties': {'name': 'Fictional iPhone', 'osVersionNumber': '27.0',
                                 'developerModeStatus': developer},
            'hardwareProperties': {'platform': 'iOS', 'marketingName': 'iPhone 16e'},
            'connectionProperties': {'pairingState': pairing, 'transportType': 'wired'}}


class CheckTests(Sandbox):
    def run_check(self, **tools):
        teams = tools.pop('teams', None)
        self.tools(teams=teams, extra=xcode_tools(**tools))
        out = io.StringIO()
        with mock.patch.dict(os.environ, self.env, clear=True), \
                mock.patch.object(configure, 'ROOT', self.repo), \
                mock.patch.object(check.platform, 'system', return_value='Darwin'), \
                mock.patch.object(check.platform, 'machine', return_value='arm64'), \
                mock.patch.object(check.platform, 'mac_ver', return_value=('26.6.2', ('', '', ''), 'arm64')), \
                contextlib.redirect_stdout(out):
            code = check.main([])
        return code, out.getvalue()

    def configured(self, team=TEAM):
        args = ['--bundle-id', BUNDLE, '--google-client-id', CLIENT] + (['--team', team] if team else [])
        self.assertEqual(self.configure(*args).returncode, 0)

    def test_ready_mac_and_iphone(self):
        self.configured()
        code, out = self.run_check(devices=[fictional_iphone()])
        self.assertEqual(code, 0, out)
        self.assertIn('ok    Xcode: 27.0', out)
        self.assertIn('ok    Xcode reads your settings', out)
        self.assertIn('Fictional iPhone', out)
        self.assertIn('Ready.', out)
        self.assertNotIn('FAIL', out)

    def test_missing_settings_file_is_blocking(self):
        code, out = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn('FAIL  Your settings', out)
        self.assertIn('configure.py --bundle-id', out)

    def test_placeholder_settings_are_blocking(self):
        (self.repo / LOCAL).write_text('CAPTURA_BUNDLE_ID = com.example.captura\n'
                                       'CAPTURA_GOOGLE_IOS_CLIENT_ID = 000000000000-example.apps.googleusercontent.com\n')
        code, out = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn('example', out)

    def test_value_cut_by_a_comment_is_reported(self):
        self.configured()
        path = self.repo / LOCAL
        path.write_text(path.read_text().replace('CAPTURA_GOOGLE_HOSTED_DOMAIN =',
                                                 'CAPTURA_GOOGLE_HOSTED_DOMAIN = https://fictional.test'))
        code, out = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn('"//"', out)

    def test_missing_ios_platform_points_to_components(self):
        self.configured()
        code, out = self.run_check(sdks=False)
        self.assertEqual(code, 1)
        self.assertIn('FAIL  iOS platform', out)
        self.assertIn('Settings > Components', out)

    def test_command_line_tools_only(self):
        self.configured()
        self.tools(extra={'xcode-select': [{'match': ['-p'], 'stdout': '/Library/Developer/CommandLineTools\n'}],
                          'xcodebuild': [{'match': [], 'rc': 1,
                                          'stderr': "xcode-select: error: tool 'xcodebuild' requires Xcode"}]})
        out = io.StringIO()
        with mock.patch.dict(os.environ, self.env, clear=True), \
                mock.patch.object(configure, 'ROOT', self.repo), contextlib.redirect_stdout(out):
            code = check.main([])
        self.assertEqual(code, 1)
        self.assertIn('FAIL  Xcode', out.getvalue())

    def test_license_not_accepted(self):
        self.configured()
        code, out = self.run_check(license_error=True)
        self.assertEqual(code, 1)
        self.assertIn('license', out)

    def test_team_picked_in_xcode_but_not_saved_points_to_adopt(self):
        self.configured(team=None)
        self.xcode_picks_team()
        code, out = self.run_check(settings_team=TEAM)
        self.assertEqual(code, 1)
        self.assertIn('--adopt-xcode-team', out)

    def test_no_team_anywhere_sends_you_on_to_step_6_instead_of_looping(self):
        self.configured(team=None)
        code, out = self.run_check(settings_team='')
        self.assertEqual(code, 1)
        self.assertIn('FAIL  Apple team: not set and no team found in Xcode', out)
        self.assertIn('Only the Apple team is missing', out)
        self.assertIn('step 6 of docs/ios.md (Open the project and check signing)', out)
        self.assertNotIn('see "Apple team"', out)

    def test_other_failures_keep_the_generic_summary(self):
        self.configured(team=None)
        code, out = self.run_check(settings_team='', sdks=False)
        self.assertEqual(code, 1)
        self.assertIn('2 problems block installing', out)
        self.assertNotIn('Only the Apple team is missing', out)

    def test_upgrade_stamps_in_the_project_are_a_warning_with_the_undo_command(self):
        self.configured()
        self.xcode_stamps_upgrade()
        code, out = self.run_check()
        self.assertEqual(code, 0, out)
        self.assertIn('warn  Xcode project', out)
        self.assertIn(f'git checkout -- {PROJECT}', out)

    def test_capital_letters_in_the_bundle_id_are_blocking(self):
        self.configured()
        path = self.repo / LOCAL
        path.write_text(path.read_text().replace(f'CAPTURA_BUNDLE_ID = {BUNDLE}',
                                                 'CAPTURA_BUNDLE_ID = Org.Fictional.Captura'))
        code, out = self.run_check(bundle='Org.Fictional.Captura')
        self.assertEqual(code, 1)
        self.assertIn(f'capital letters; use {BUNDLE}', out)

    def test_help_explains_the_check_without_running_it(self):
        result = subprocess.run([sys.executable, str(self.repo / 'ios/scripts/check.py'), '--help'],
                                cwd=self.repo, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('usage: python3 ios/scripts/check.py', result.stdout)
        self.assertIn('Read-only', result.stdout)
        self.assertNotIn('Captura iOS check', result.stdout)

    def test_missing_team_with_one_known_team_points_to_configure(self):
        self.configured(team=None)
        code, out = self.run_check(teams=personal_teams(TEAM), settings_team='')
        self.assertEqual(code, 1)
        self.assertIn(f'Xcode knows {TEAM}', out)

    def test_developer_mode_off_is_a_spanish_hint_not_a_blocker(self):
        self.configured()
        code, out = self.run_check(devices=[fictional_iphone(developer='disabled')])
        self.assertEqual(code, 0, out)
        self.assertIn('Configuración > Privacidad y seguridad > Modo de desarrollador', out)

    def test_xcode_seeing_another_bundle_id_is_blocking(self):
        self.configured()
        code, out = self.run_check(bundle='org.example.captura')
        self.assertEqual(code, 1)
        self.assertIn('Xcode sees bundle ID', out)


if __name__ == '__main__':
    unittest.main()
