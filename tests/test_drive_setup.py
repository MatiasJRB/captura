"""scripts/secret_refs.py and `capture drive-setup`. Fake op, security and rclone on PATH,
temporary HOME, fictional values only; no network, no real password manager or Google.

Every fake tool logs its arguments and environment (FAKE_TOOLS_LOG), so each test can
check that the secret never reached a child process, the output or an error.
"""
import configparser
import contextlib
import io
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(ROOT / 'worker'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import fake_tools  # noqa: E402
import secret_refs  # noqa: E402
import drive_setup  # noqa: E402

CLI = str(ROOT / 'bin/capture')
CLIENT = '481516234200-fictionaldesktop.apps.googleusercontent.com'
SECRET = 'GOCSPX-fictionalSecretValue0123'
TOKEN = 'fictional-rclone-access-token'
ITEM = 'op://Captura/Captura worker OAuth'
SIGNED_OUT = '[ERROR] 2026/10/07 12:00:00 account is not signed in\n'


def op_item(fields):
    return json.dumps(dict(id='fictionalitemid', title='Captura worker OAuth', fields=[
        dict(id=f'f{i}', label=label, type='CONCEALED' if 'secret' in label else 'STRING', value=value)
        for i, (label, value) in enumerate(fields.items())]))


OP_OK = [
    {'match': ['item', 'get', 'Captura worker OAuth', '--vault', 'Captura'],
     'stdout': op_item({'client_id': CLIENT, 'client_secret': SECRET, 'notes': 'fictional'})},
    {'match': ['read', ITEM + '/client_secret'], 'stdout': SECRET},
    {'match': ['read', ITEM + '/client_id'], 'stdout': CLIENT + '\n'},
    {'match': ['item', 'get'], 'rc': 1, 'stderr': '[ERROR] "Nope" isn\'t an item in the "Captura" vault.\n'},
    {'match': ['read'], 'rc': 1, 'stderr': '[ERROR] could not read secret: "nope" isn\'t a field in the item.\n'},
]
SECURITY = [
    {'match': ['find-generic-password', '-s', 'Captura worker OAuth', '-a', 'client_id', '-w'], 'stdout': CLIENT + '\n'},
    {'match': ['find-generic-password', '-s', 'Captura worker OAuth', '-a', 'client_secret', '-w'],
     'stdout': SECRET + '\n'},
    {'match': ['find-generic-password'], 'rc': 44,
     'stderr': 'security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.\n'},
]
# rclone's browser sign-in, faked: logs the call, then saves a token like rclone does.
RCLONE = '''#!{python}
import configparser, json, os, sys
args = sys.argv[1:]
with open(os.environ['FAKE_TOOLS_LOG'], 'a') as log:
    log.write(json.dumps(dict(tool='rclone', args=args, env=dict(os.environ))) + '\\n')
if os.environ.get('FAKE_RCLONE_FAIL'):
    print('Failed to configure token: fictional failure')
    sys.exit(1)
if 'reconnect' in args:
    path = args[args.index('--config') + 1]
    remote = args[args.index('reconnect') + 1].rstrip(':')
    parser = configparser.RawConfigParser(interpolation=None)
    parser.read(path)
    parser[remote]['token'] = json.dumps(dict(access_token={token!r}, token_type='Bearer'))
    with open(path, 'w') as out:
        parser.write(out)
    print('Waiting for code...')
    sys.exit(0)
sys.exit(0)
'''


class Home:
    """A temporary HOME with fake op, security and rclone first on PATH."""

    def __init__(self, tmp, op=True):
        tmp = Path(tmp)
        self.home = tmp / 'home'
        self.home.mkdir()
        self.bin = tmp / 'bin'
        spec = {'security': SECURITY}
        if op:
            spec['op'] = OP_OK
        fake_tools.install(self.bin, spec)
        rclone = self.bin / 'rclone'
        rclone.write_text(RCLONE.format(python=sys.executable, token=TOKEN))
        os.chmod(rclone, 0o755)
        self.log = tmp / 'calls.jsonl'
        self.env = dict(os.environ, HOME=str(self.home), PATH=f'{self.bin}:/usr/bin:/bin',
                        FAKE_TOOLS_LOG=str(self.log))
        for key in ('RCLONE_CONFIG', 'XDG_CONFIG_HOME', 'FAKE_RCLONE_FAIL'):
            self.env.pop(key, None)
        self.conf = self.home / '.config/rclone/rclone.conf'
        self.config = self.home / 'Library/Application Support/Captura/config.json'

    def op_spec(self, rules):
        fake_tools.install(self.bin, {'op': rules, 'security': SECURITY})

    def cli(self, *args, env=None):
        return subprocess.run([sys.executable, CLI, *args], capture_output=True, text=True,
                              env=dict(self.env, **(env or {})), stdin=subprocess.DEVNULL)

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def section(self, remote='captura'):
        parser = configparser.RawConfigParser(interpolation=None)
        parser.read(self.conf)
        return dict(parser[remote]) if parser.has_section(remote) else None


class SecretSafety:
    def assert_secret_kept(self, home, *outputs):
        for output in outputs:
            self.assertNotIn(SECRET, output)
            self.assertNotIn(TOKEN, output)
        for call in home.calls():
            with self.subTest(tool=call['tool'], args=call['args']):
                self.assertNotIn(SECRET, ' '.join(call['args']))
                self.assertNotIn(SECRET, ' '.join(call['env'].values()))


class DriveSetupTests(SecretSafety, unittest.TestCase):
    def test_item_reference_writes_a_private_remote_and_signs_in(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Home(tmp)
            result = home.cli('drive-setup', '--from', ITEM)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(result.stdout)  # stdout stays pure JSON; rclone talks on stderr
            self.assertEqual(report['state'], 'drive_remote_ready')
            self.assertEqual((report['remote'], report['scope'], report['authorized']), ('captura', 'drive.file', True))
            self.assertEqual(stat.S_IMODE(home.conf.stat().st_mode), 0o600)
            section = home.section()
            self.assertEqual((section['type'], section['client_id'], section['client_secret'], section['scope']),
                             ('drive', CLIENT, SECRET, 'drive.file'))
            self.assertIn('Waiting for code', result.stderr)
            # No worker config yet: init comes next.
            self.assertIn(' init --account YOUR-GOOGLE-ADDRESS', report['next_step'])
            tools = [(c['tool'], c['args'][:2]) for c in home.calls()]
            self.assertIn(('op', ['item', 'get']), tools)
            reconnect = [c['args'] for c in home.calls() if c['tool'] == 'rclone']
            self.assertEqual(reconnect, [['--config', str(home.conf), 'config', 'reconnect', 'captura:']])
            self.assert_secret_kept(home, result.stdout, result.stderr)

    def test_existing_worker_config_points_to_doctor_and_supplies_remote_and_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Home(tmp)
            self.assertEqual(home.cli('init', '--account', 'person@fictional.test', '--remote', 'phone').returncode, 0)
            result = home.cli('drive-setup', '--from', ITEM, '--scope', 'drive.readonly')
            report = json.loads(result.stdout)
            self.assertEqual(report['state'], 'drive_remote_ready', report)
            self.assertEqual((report['remote'], report['scope']), ('phone', 'drive.readonly'))
            self.assertIn(' doctor --config ', report['next_step'])
            self.assertEqual(home.section('phone')['scope'], 'drive.readonly')
            self.assert_secret_kept(home, result.stdout, result.stderr)

    def test_refuses_to_overwrite_an_existing_remote_without_force(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Home(tmp)
            home.conf.parent.mkdir(parents=True)
            original = ('[other]\ntype = s3\nprovider = Fictional\n\n'
                        '[captura]\ntype = drive\nscope = drive\ntoken = {"access_token": "old-fictional"}\n')
            home.conf.write_text(original)
            result = home.cli('drive-setup', '--from', ITEM)
            report = json.loads(result.stdout)
            self.assertEqual((result.returncode, report['error']), (1, 'remote_exists'))
            self.assertIn('--force', report['note'])
            self.assertEqual(home.conf.read_text(), original)
            self.assertEqual(home.calls(), [], 'nothing is read before the refusal')

            result = home.cli('drive-setup', '--from', ITEM, '--force')
            self.assertEqual(json.loads(result.stdout)['state'], 'drive_remote_ready', result.stdout)
            self.assertEqual(home.section('other'), {'type': 's3', 'provider': 'Fictional'})
            section = home.section()
            self.assertEqual(section['scope'], 'drive.file')
            self.assertNotIn('old-fictional', section['token'])
            self.assertEqual(stat.S_IMODE(home.conf.stat().st_mode), 0o600)
            self.assert_secret_kept(home, result.stdout, result.stderr)

    def test_field_map_names_other_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Home(tmp)
            home.op_spec([{'match': ['item', 'get', 'Captura worker OAuth'],
                           'stdout': op_item({'Desktop client ID': CLIENT, 'credential': SECRET})}])
            missing = home.cli('drive-setup', '--from', ITEM, '--no-login')
            report = json.loads(missing.stdout)
            self.assertEqual(report['error'], 'secret_unavailable')
            self.assertIn('"client_id" or "client_secret"', report['next_step'])
            result = home.cli('drive-setup', '--from', ITEM, '--field-map', 'client_id=Desktop client ID',
                              '--field-map', 'client_secret=credential')
            self.assertEqual(json.loads(result.stdout)['state'], 'drive_remote_ready', result.stdout)
            self.assertEqual(home.section()['client_secret'], SECRET)
            self.assert_secret_kept(home, missing.stdout, missing.stderr, result.stdout, result.stderr)

    def test_single_value_references_from_op_keychain_and_env(self):
        cases = [
            (['--client-id-ref', ITEM + '/client_id', '--client-secret-ref', ITEM + '/client_secret'], {}),
            (['--from', 'keychain://Captura worker OAuth'], {}),
            (['--client-id-ref', 'keychain://Captura worker OAuth/client_id',
              '--client-secret-ref', 'env:FICTIONAL_DESKTOP_SECRET'], {'FICTIONAL_DESKTOP_SECRET': SECRET}),
        ]
        for args, env in cases:
            with self.subTest(args=args), tempfile.TemporaryDirectory() as tmp:
                home = Home(tmp)
                result = home.cli('drive-setup', *args, env=env)
                self.assertEqual(json.loads(result.stdout)['state'], 'drive_remote_ready', result.stdout + result.stderr)
                self.assertEqual(home.section()['client_secret'], SECRET)
                self.assertEqual(home.section()['client_id'], CLIENT)
                self.assert_secret_kept(home, result.stdout, result.stderr)

    def test_missing_op_and_signed_out_op_get_clear_advice(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Home(tmp, op=False)
            result = home.cli('drive-setup', '--from', ITEM)
            report = json.loads(result.stdout)
            self.assertEqual((result.returncode, report['error']), (1, 'secret_unavailable'))
            self.assertIn('1Password CLI ("op") is not installed', report['next_step'])
            self.assertFalse(home.conf.exists())

            home.op_spec([{'match': ['item', 'get'], 'rc': 1, 'stderr': SIGNED_OUT},
                          {'match': ['read'], 'rc': 1, 'stderr': SIGNED_OUT}])
            for args in (['--from', ITEM], ['--client-secret-ref', ITEM + '/client_secret',
                                            '--client-id-ref', ITEM + '/client_id']):
                with self.subTest(args=args):
                    report = json.loads(home.cli('drive-setup', *args).stdout)
                    self.assertIn('not signed in', report['next_step'])
                    self.assertIn('Integrate with 1Password CLI', report['next_step'])
            self.assertFalse(home.conf.exists())

    def test_missing_item_field_and_keychain_entry_name_the_reference(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Home(tmp)
            cases = [
                (['--from', 'op://Captura/Nope'], 'no item "Nope"'),
                (['--client-id-ref', ITEM + '/nope',
                  '--client-secret-ref', ITEM + '/client_secret'], 'no such field'),
                (['--from', 'keychain://Fictional missing service'], 'no "client_id" or "client_secret" field'),
                (['--client-id-ref', 'keychain://Fictional/client_id',
                  '--client-secret-ref', 'keychain://Captura worker OAuth/client_secret'],
                 'security add-generic-password -s "Fictional" -a client_id -w'),
                (['--client-id-ref', ITEM + '/client_id', '--client-secret-ref', 'env:UNSET_FICTIONAL'],
                 'UNSET_FICTIONAL is not set'),
                (['--client-id-ref', 'https://fictional.test/x', '--client-secret-ref', 'env:X'],
                 'not a reference this script reads'),
            ]
            for args, phrase in cases:
                with self.subTest(phrase=phrase):
                    result = home.cli('drive-setup', *args)
                    report = json.loads(result.stdout)
                    self.assertEqual(report['error'], 'secret_unavailable')
                    self.assertIn(phrase, report['next_step'])
                    self.assert_secret_kept(home, result.stdout, result.stderr)
            self.assertFalse(home.conf.exists())

    def test_bad_values_are_refused_without_echoing_them(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Home(tmp)
            bad_secret = 'fictional secret with spaces'
            cases = [
                ({'FICTIONAL_ID': CLIENT, 'FICTIONAL_SECRET': bad_secret}, 'invalid_client_secret'),
                ({'FICTIONAL_ID': CLIENT, 'FICTIONAL_SECRET': 'PASTE-THE-SECRET'}, 'placeholder_client_secret'),
                ({'FICTIONAL_ID': 'com.googleusercontent.apps.fictional', 'FICTIONAL_SECRET': SECRET},
                 'invalid_client_id'),
            ]
            for env, code in cases:
                with self.subTest(code=code):
                    result = home.cli('drive-setup', '--client-id-ref', 'env:FICTIONAL_ID',
                                      '--client-secret-ref', 'env:FICTIONAL_SECRET', env=env)
                    self.assertEqual(json.loads(result.stdout)['error'], code)
                    self.assertNotIn(env['FICTIONAL_SECRET'], result.stdout + result.stderr)
            self.assertFalse(home.conf.exists())

    def test_without_a_terminal_or_reference_it_asks_for_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Home(tmp)
            report = json.loads(home.cli('drive-setup').stdout)
            self.assertEqual(report['error'], 'secret_unavailable')
            self.assertIn('No terminal', report['next_step'])

    def test_failed_sign_in_keeps_the_remote_and_gives_the_reconnect_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Home(tmp)
            result = home.cli('drive-setup', '--from', ITEM, env={'FAKE_RCLONE_FAIL': '1'})
            report = json.loads(result.stdout)
            self.assertEqual((result.returncode, report['error']), (1, 'rclone_sign_in_failed'))
            self.assertEqual(report['next_step'], 'rclone config reconnect captura:')
            self.assertEqual(home.section()['client_secret'], SECRET)
            self.assert_secret_kept(home, result.stdout, result.stderr)

    def test_no_login_only_writes_and_custom_config_path_is_used(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Home(tmp)
            custom = Path(tmp) / 'custom dir/rclone.conf'
            result = home.cli('drive-setup', '--from', ITEM, '--no-login', '--rclone-config', str(custom),
                              '--remote', 'phone')
            report = json.loads(result.stdout)
            self.assertEqual((report['state'], report['authorized']), ('remote_written', False))
            self.assertTrue(report['next_step'].startswith('rclone --config '), report['next_step'])
            self.assertTrue(report['next_step'].endswith(' config reconnect phone:'))
            self.assertEqual(stat.S_IMODE(custom.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(custom.parent.stat().st_mode), 0o700)
            self.assertNotIn('rclone', [c['tool'] for c in home.calls()])
            self.assert_secret_kept(home, result.stdout, result.stderr)

    def test_encrypted_rclone_config_is_left_alone(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Home(tmp)
            home.conf.parent.mkdir(parents=True)
            text = '# Encrypted rclone configuration File\n\nRCLONE_ENCRYPT_V0:\nZmljdGlvbmFs\n'
            home.conf.write_text(text)
            report = json.loads(home.cli('drive-setup', '--from', ITEM).stdout)
            self.assertEqual(report['error'], 'rclone_config_encrypted')
            self.assertEqual(home.conf.read_text(), text)


class DoctorAdviceTests(unittest.TestCase):
    def test_doctor_and_probe_offer_drive_setup_when_there_is_no_remote(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Home(tmp)
            home.cli('init', '--account', 'person@fictional.test')
            report = json.loads(home.cli('doctor').stdout)
            check = {c['check']: c for c in report['checks']}['rclone_remote']
            self.assertEqual(check['alternative'], f'python3 {shlex.quote(CLI)} drive-setup')
            self.assertIn('--from', check['note'])
            probe = json.loads(home.cli('probe').stdout)
            self.assertEqual(probe['alternative'], f'python3 {shlex.quote(CLI)} drive-setup')

    def test_remote_to_recreate_names_drive_setup_with_force(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Home(tmp)
            home.cli('init', '--account', 'person@fictional.test')
            home.conf.parent.mkdir(parents=True)
            home.conf.write_text('[captura]\ntype = s3\n')
            check = {c['check']: c for c in json.loads(home.cli('doctor').stdout)['checks']}['rclone_remote']
            self.assertIn(f'"python3 {shlex.quote(CLI)} drive-setup --force"', check['next_step'])


class SecretRefsUnitTests(unittest.TestCase):
    def test_reference_kinds(self):
        self.assertEqual(secret_refs.kind('op://Vault/Item/field'), 'op')
        self.assertEqual(secret_refs.kind('op://Vault/Item'), 'op_item')
        self.assertEqual(secret_refs.kind('keychain://service/account'), 'keychain')
        self.assertEqual(secret_refs.kind('keychain://service'), 'keychain_item')
        self.assertEqual(secret_refs.kind('env:NAME'), 'env')
        for bad in ('op://Vault', 'keychain://', 'env:', 'plain-value', ''):
            with self.subTest(ref=bad), self.assertRaises(secret_refs.SecretRefError):
                secret_refs.kind(bad)

    def test_unset_variable_error_names_only_the_variable(self):
        with self.assertRaises(secret_refs.SecretRefError) as caught:
            secret_refs.resolve('env:UNSET_FICTIONAL_NAME', environ={})
        self.assertIn('UNSET_FICTIONAL_NAME', str(caught.exception))

    def test_env_reference_and_empty_value(self):
        self.assertEqual(secret_refs.resolve('env:A', environ={'A': SECRET}), SECRET)
        with self.assertRaises(secret_refs.SecretRefError):
            secret_refs.resolve('env:A', environ={'A': '  '})

    def test_field_map(self):
        self.assertEqual(secret_refs.parse_field_map(['client_id="Desktop client ID",client_secret=credential'],
                                                     ('client_id', 'client_secret')),
                         {'client_id': 'Desktop client ID', 'client_secret': 'credential'})
        for bad in (['client_id'], ['unknown=x'], ['client_id=']):
            with self.subTest(entry=bad), self.assertRaises(secret_refs.SecretRefError):
                secret_refs.parse_field_map(bad, ('client_id', 'client_secret'))

    def test_hidden_prompt_uses_getpass_and_reports_only_the_length(self):
        tty = mock.Mock(isatty=lambda: True)
        err = io.StringIO()
        with mock.patch('getpass.getpass', return_value=SECRET + '\n') as hidden, \
                contextlib.redirect_stderr(err):
            self.assertEqual(secret_refs.prompt('Desktop client secret', True, stdin=tty), SECRET)
        hidden.assert_called_once()
        self.assertIn(f'Got {len(SECRET)} characters.', err.getvalue())
        self.assertNotIn(SECRET, err.getvalue())

    def test_values_come_from_refs_then_item_then_prompt(self):
        asked = []

        def ask(label, secret):
            asked.append((label, secret))
            return SECRET if secret else CLIENT
        with mock.patch.dict(os.environ, {'FICTIONAL_ID': CLIENT}):
            self.assertEqual(drive_setup.read_values(client_id_ref='env:FICTIONAL_ID', ask=ask), (CLIENT, SECRET))
        self.assertEqual(asked, [('Desktop client secret', True)])

    def test_section_replacement_keeps_other_remotes_verbatim(self):
        text = '; fictional comment\n[a]\ntype = s3\n\n[captura]\ntype = drive\ntoken = x\n\n[b]\ntype = local\n'
        new = drive_setup.replace_section(text, 'captura', '[captura]\ntype = drive\n')
        self.assertEqual(new, '; fictional comment\n[a]\ntype = s3\n\n[captura]\ntype = drive\n\n[b]\ntype = local\n')
        self.assertEqual(drive_setup.replace_section('[a]\ntype = s3', 'c', '[c]\n'), '[a]\ntype = s3\n\n[c]\n')
        self.assertEqual(drive_setup.replace_section('', 'c', '[c]\n'), '[c]\n')


if __name__ == '__main__':
    unittest.main()
