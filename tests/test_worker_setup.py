"""capture init / doctor / pin and next-step hints. Fake tools only, temp dirs, no network."""
import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'worker'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import fake_tools  # noqa: E402
import onboarding  # noqa: E402

CLI = str(ROOT / 'bin/capture')
SECRET = 'fictional-client-secret-value'
TOKEN = 'fictional-access'
# Shaped like a folder ID the phone creates (33 characters); fictional.
FOLDER = '1fictionalDriveId0123456789abcdef'
WHISPER_HELP = 'echo "usage: whisper-cli [options]" >&2; echo "  --vad  enable VAD" >&2; echo "  -vm FNAME, --vad-model FNAME" >&2'


def rclone_section(name='captura', scope='drive.file', client=True, token=True):
    lines = [f'[{name}]', 'type = drive', f'scope = {scope}']
    if client:
        lines += ['client_id = 123456789012-fictional.apps.googleusercontent.com', f'client_secret = {SECRET}']
    if token:
        lines.append('token = ' + json.dumps(dict(access_token=TOKEN, token_type='Bearer',
                                                     expiry='2026-10-06T00:00:00Z')))
    return '\n'.join(lines) + '\n'


_TOOLS = {}


def setUpModule():
    _TOOLS['tmp'] = tempfile.TemporaryDirectory()


def tearDownModule():
    _TOOLS.pop('tmp').cleanup()


def fake_bin(whisper_help):
    """Fake ffmpeg/whisper-cli/rclone, written once per variant: new executables are slow
    to start the first time on macOS."""
    if whisper_help not in _TOOLS:
        directory = Path(_TOOLS['tmp'].name) / f'bin{len(_TOOLS)}'
        directory.mkdir()
        fake_tools.script(directory, 'ffmpeg', 'exit 0')
        fake_tools.script(directory, 'whisper-cli', whisper_help + '\nexit 0')
        fake_tools.script(directory, 'rclone', 'exit 0')
        _TOOLS[whisper_help] = directory
    return _TOOLS[whisper_help]


class SetupHome:
    """A temporary HOME with fake ffmpeg/whisper-cli/rclone and correctly sized models."""

    def __init__(self, tmp, whisper_help=WHISPER_HELP):
        self.home = Path(tmp) / 'home'
        self.home.mkdir()
        self.bin = fake_bin(whisper_help)
        self.env = dict(os.environ, HOME=str(self.home), PATH=f'{self.bin}:/usr/bin:/bin')
        for key in ('RCLONE_CONFIG', 'XDG_CONFIG_HOME'):
            self.env.pop(key, None)
        self.config = self.home / 'Library/Application Support/Captura/config.json'
        self.rclone_conf = self.home / '.config/rclone/rclone.conf'

    def models(self, model_size=None, vad_size=None):
        cache = self.home / '.cache/whisper'
        cache.mkdir(parents=True, exist_ok=True)
        for name, size in (('ggml-large-v3-turbo.bin', model_size), ('ggml-silero-v6.2.0.bin', vad_size)):
            with (cache / name).open('wb') as stream:
                stream.write(b'lmgg')
                stream.truncate(size or onboarding.KNOWN_SIZES[name])  # sparse: no real disk use

    def remote(self, text):
        self.rclone_conf.parent.mkdir(parents=True, exist_ok=True)
        self.rclone_conf.write_text(text)

    def cli(self, *args):
        return subprocess.run([sys.executable, CLI, *args], capture_output=True, text=True, env=self.env)

    def cli_at_terminal(self, *args):
        """Runs the CLI with stderr on a pseudo-terminal, as in Terminal. Returns (stdout, stderr).

        Our end of the terminal stays open until it is drained: on macOS, output still in
        the buffer is lost once every handle to the terminal side is closed.
        """
        main, child = pty.openpty()
        chunks = []
        try:
            process = subprocess.Popen([sys.executable, CLI, *args], stdout=subprocess.PIPE, stderr=child,
                                       stdin=subprocess.DEVNULL, env=self.env)
            while True:
                if select.select([main], [], [], 0.05)[0]:
                    chunks.append(os.read(main, 65536))
                elif process.poll() is not None:
                    while select.select([main], [], [], 0.2)[0]:
                        chunks.append(os.read(main, 65536))
                    break
            stdout = process.stdout.read().decode()
            process.stdout.close()
        finally:
            os.close(child)
            os.close(main)
        return stdout, b''.join(chunks).decode().replace('\r\n', '\n')

    def doctor(self):
        result = self.cli('doctor')
        return result, json.loads(result.stdout)


def by_check(report):
    return {c['check']: c for c in report['checks']}


class InitTests(unittest.TestCase):
    def test_init_writes_private_config_with_defaults_and_tool_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            result = env.cli('init', '--account', 'person@fictional.test')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(stat.S_IMODE(env.config.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(env.config.parent.stat().st_mode), 0o700)
            config = json.loads(env.config.read_text())
            self.assertEqual(config['remote'], 'captura')
            self.assertEqual(config['root'], '~/Library/Application Support/Captura/inbox')
            self.assertEqual(config['model'], '~/.cache/whisper/ggml-large-v3-turbo.bin')
            self.assertEqual(config['vad_model'], '~/.cache/whisper/ggml-silero-v6.2.0.bin')
            self.assertEqual(config['rclone_config'], '~/.config/rclone/rclone.conf')
            self.assertEqual((config['language'], config['transcribe'], config['folder_id']), ('es', True, ''))
            self.assertEqual(config['whisper'], str(env.bin / 'whisper-cli'))
            self.assertIn('doctor', json.loads(result.stdout)['next_step'])

    def test_init_never_overwrites_without_force(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            env.cli('init', '--account', 'person@fictional.test')
            env.cli('pin', '--folder-id', FOLDER)
            again = env.cli('init', '--account', 'other@fictional.test')
            self.assertEqual(again.returncode, 1)
            self.assertEqual(json.loads(again.stdout)['error'], 'config_exists')
            self.assertEqual(json.loads(env.config.read_text())['folder_id'], FOLDER)
            forced = env.cli('init', '--account', 'other@fictional.test', '--force')
            self.assertEqual(forced.returncode, 0, forced.stderr)
            config = json.loads(env.config.read_text())
            self.assertEqual((config['expected_account'], config['folder_id']), ('other@fictional.test', ''))
            self.assertEqual(stat.S_IMODE(env.config.stat().st_mode), 0o600)

    def test_init_rejects_placeholder_account(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            for account in ('you@example.com', 'you@yourcompany.com', 'you@yourdomain.com'):
                result = env.cli('init', '--account', account)
                self.assertEqual(result.returncode, 1, account)
            self.assertFalse(env.config.exists())

    def test_init_takes_root_language_and_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            result = env.cli('init', '--account', 'person@fictional.test', '--root', str(env.home / 'Transcripts'),
                             '--language', 'en', '--model', '~/.cache/whisper/ggml-small.bin')
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads(env.config.read_text())
            self.assertEqual((config['root'], config['language'], config['model']),
                             ('~/Transcripts', 'en', '~/.cache/whisper/ggml-small.bin'))
            bad = env.cli('init', '--account', 'person@fictional.test', '--language', 'Spanish', '--force')
            self.assertEqual(json.loads(bad.stdout)['error'], 'invalid_language')

    def test_existing_config_offers_set_for_the_values_you_passed(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            env.cli('init', '--account', 'person@fictional.test')
            plain = json.loads(env.cli('init', '--account', 'person@fictional.test').stdout)
            self.assertIn(' doctor --config ', plain['next_step'])
            self.assertIn('--force', plain['note'])
            again = json.loads(env.cli('init', '--account', 'person@fictional.test',
                                       '--model', '~/.cache/whisper/ggml-small.bin').stdout)
            self.assertEqual(again['error'], 'config_exists')
            self.assertEqual(again['next_step'],
                             'python3 ' + CLI + ' set --config "$HOME/Library/Application Support/Captura/config.json"'
                             ' --model "$HOME/.cache/whisper/ggml-small.bin"')


class SetTests(unittest.TestCase):
    def test_set_changes_only_what_you_name_and_keeps_the_pinned_folder(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            env.cli('init', '--account', 'person@fictional.test')
            env.cli('pin', '--folder-id', FOLDER)
            before = json.loads(env.config.read_text())
            result = env.cli('set', '--model', str(env.home / '.cache/whisper/ggml-small.bin'), '--language', 'auto')
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(report['state'], 'config_updated')
            self.assertIn(' doctor --config ', report['next_step'])
            after = json.loads(env.config.read_text())
            self.assertEqual((after['model'], after['language'], after['folder_id']),
                             ('~/.cache/whisper/ggml-small.bin', 'auto', FOLDER))
            for key in ('model', 'language'):
                before.pop(key), after.pop(key)
            self.assertEqual(after, before)
            self.assertEqual(stat.S_IMODE(env.config.stat().st_mode), 0o600)

    def test_set_rejects_bad_values_and_needs_a_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            missing = json.loads(env.cli('set', '--language', 'es').stdout)
            self.assertEqual(missing['error'], 'config_not_found')
            self.assertIn('step 4', missing['next_step'])
            env.cli('init', '--account', 'person@fictional.test')
            self.assertEqual(json.loads(env.cli('set', '--language', 'es-MX').stdout)['error'], 'invalid_language')
            self.assertEqual(json.loads(env.cli('set').stdout)['error'], 'nothing_to_set')
            changed = json.loads(env.cli('set', '--account', 'other@fictional.test').stdout)
            self.assertEqual(changed['changed']['expected_account']['new'], 'other@fictional.test')


class DoctorTests(unittest.TestCase):
    def ready_env(self, tmp, **kwargs):
        env = SetupHome(tmp, **kwargs)
        env.cli('init', '--account', 'person@fictional.test')
        env.models()
        env.remote(rclone_section())
        return env

    def test_ready_setup_points_to_probe_and_hides_secrets(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = self.ready_env(tmp)
            result, report = env.doctor()
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual(report['state'], 'ready_with_warnings')
            checks = by_check(report)
            self.assertEqual(checks['rclone_remote']['status'], 'ok')
            self.assertIn('drive.file', checks['rclone_remote']['detail'])
            self.assertEqual(checks['folder_id']['status'], 'warn')
            self.assertIn(' probe --config "$HOME/Library/Application Support/Captura/config.json"',
                          report['next_step'])
            self.assertNotIn(SECRET, result.stdout + result.stderr)
            self.assertNotIn(TOKEN, result.stdout + result.stderr)

    def test_pinned_setup_points_to_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = self.ready_env(tmp)
            env.cli('pin', '--folder-id', FOLDER)
            result, report = env.doctor()
            self.assertEqual((result.returncode, report['state']), (0, 'ready'))
            self.assertIn(' run --config ', report['next_step'])

    def test_missing_tools_and_models_block_with_install_steps(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            env.cli('init', '--account', 'person@fictional.test')
            config = json.loads(env.config.read_text())
            config['ffmpeg'] = 'ffmpeg-not-installed'
            env.config.write_text(json.dumps(config))
            result, report = env.doctor()
            self.assertEqual((result.returncode, report['state']), (1, 'blocked'))
            checks = by_check(report)
            self.assertEqual(checks['ffmpeg']['next_step'], 'brew install ffmpeg')
            self.assertEqual(checks['model']['status'], 'fail')
            self.assertIn('curl -L --fail -o "$HOME/.cache/whisper/ggml-large-v3-turbo.bin" https://huggingface.co/',
                          checks['model']['next_step'])
            # Points to the doc step that keeps the secret out of the shell history.
            self.assertEqual(checks['rclone_remote']['next_step'], onboarding.STEP_3)
            self.assertNotIn('client_secret', result.stdout)
            self.assertEqual(report['next_step'], 'brew install ffmpeg')
            self.assertEqual(report['also_failing'][:2], ['model', 'vad_model'])

    def test_every_next_step_is_a_command_or_prose_never_both(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            env.cli('init', '--account', 'person@fictional.test')
            env.models(model_size=500 * 1000 * 1000)
            env.remote(rclone_section(token=False))
            _, report = env.doctor()
            commands = ('curl ', 'mkdir ', 'python3 ', 'rclone ', 'brew ', 'chmod ')
            for check in report['checks']:
                step = check.get('next_step', '')
                with self.subTest(check=check['check']):
                    if not step.startswith(commands):
                        # Prose may name a command in quotes, but never ends with one to paste.
                        self.assertIsNone(re.search(r':\s*(curl|mkdir|python3|rclone|brew|chmod) ', step), step)
            self.assertTrue(by_check(report)['model']['next_step'].startswith('curl -L --fail -o "$HOME/'))
            self.assertEqual(by_check(report)['rclone_remote']['next_step'], 'rclone config reconnect captura:')
            self.assertIn('person@fictional.test', by_check(report)['rclone_remote']['note'])

    def test_missing_model_mentions_a_smaller_one_already_downloaded(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = self.ready_env(tmp)
            cache = env.home / '.cache/whisper'
            (cache / 'ggml-large-v3-turbo.bin').unlink()
            (cache / 'ggml-small.bin').write_bytes(b'lmgg')
            _, report = env.doctor()
            model = by_check(report)['model']
            self.assertEqual(model['status'], 'fail')
            self.assertIn('also in that folder: ggml-small.bin', model['detail'])
            self.assertTrue(model['next_step'].startswith('mkdir -p "$HOME/.cache/whisper" && curl '))
            self.assertTrue(model['alternative'].endswith(' set --config "$HOME/Library/Application Support/'
                                                          'Captura/config.json" --model "$HOME/.cache/whisper/ggml-small.bin"'))
            self.assertEqual(report['alternative'], model['alternative'])

    def test_terminal_gets_plain_commands_without_json_escapes(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = self.ready_env(tmp)
            (env.home / '.cache/whisper/ggml-large-v3-turbo.bin').unlink()
            (env.home / '.cache/whisper/ggml-small.bin').write_bytes(b'lmgg')
            stdout, terminal = env.cli_at_terminal('doctor')
            self.assertEqual(json.loads(stdout)['state'], 'blocked')
            lines = {line.split(':', 1)[0]: line for line in terminal.strip().splitlines()}
            next_line = lines['Next'][len('Next: '):]
            self.assertTrue(next_line.startswith('mkdir -p "$HOME/.cache/whisper" && curl '), terminal)
            self.assertNotIn('\\', terminal)
            # As the shell reads it: no argument keeps a literal quote character.
            self.assertFalse([word for word in shlex.split(next_line) if '"' in word])
            self.assertIn('--model "$HOME/.cache/whisper/ggml-small.bin"', lines['Or'])
            piped = env.cli('doctor')
            self.assertEqual(piped.stderr, '')

    def test_pinned_placeholder_from_an_older_version_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = self.ready_env(tmp)
            config = json.loads(env.config.read_text())
            config['folder_id'] = 'PASTE-THE-FOLDER-ID'
            env.config.write_text(json.dumps(config))
            _, report = env.doctor()
            self.assertEqual(by_check(report)['folder_id']['status'], 'fail')
            self.assertIn(' probe --config ', by_check(report)['folder_id']['next_step'])

    def test_whisper_without_vad_is_blocking(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = self.ready_env(tmp, whisper_help='echo "usage: whisper-cli [options]"')
            result, report = env.doctor()
            self.assertEqual(result.returncode, 1)
            self.assertEqual(by_check(report)['whisper_vad']['status'], 'fail')

    def test_incomplete_model_download_is_blocking(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = self.ready_env(tmp)
            env.models(model_size=500 * 1000 * 1000)
            result, report = env.doctor()
            self.assertEqual(result.returncode, 1)
            self.assertIn('incomplete download', by_check(report)['model']['detail'])

    def test_html_error_page_instead_of_vad_model_is_blocking(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = self.ready_env(tmp)
            (env.home / '.cache/whisper/ggml-silero-v6.2.0.bin').write_text('<!DOCTYPE html><title>404</title>')
            result, report = env.doctor()
            self.assertEqual(result.returncode, 1)
            self.assertIn('web page', by_check(report)['vad_model']['detail'])

    def test_rclone_remote_problems(self):
        mistyped = rclone_section().replace('123456789012-fictional.apps.googleusercontent.com',
                                            '123456789012-fictional.apps.googleusercontent')
        cases = [
            (rclone_section(name='other'), 'fail', 'no remote named "captura"'),
            (mistyped, 'fail', 'does not look like a Google client ID'),
            (rclone_section(token=False), 'fail', 'not authorized'),
            (rclone_section(client=False), 'warn', 'shared Google client'),
            (rclone_section(scope=''), 'warn', 'full access'),
            (rclone_section(scope='drive.readonly'), 'ok', 'drive.readonly'),
            ('# Encrypted rclone configuration File\n\nRCLONE_ENCRYPT_V0:\nZmljdGlvbmFs\n', 'fail', 'encrypted'),
            ('[captura]\ntype = s3\n', 'fail', 'not drive'),
        ]
        for text, status, phrase in cases:
            with self.subTest(phrase=phrase), tempfile.TemporaryDirectory() as tmp:
                env = self.ready_env(tmp)
                env.remote(text)
                result, report = env.doctor()
                check = by_check(report)['rclone_remote']
                self.assertEqual(check['status'], status, check)
                self.assertIn(phrase, check['detail'])
                self.assertEqual(result.returncode, 1 if status == 'fail' else 0)
                self.assertNotIn(SECRET, result.stdout)
                self.assertNotIn(TOKEN, result.stdout)

    def test_missing_config_points_to_init(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            result, report = env.doctor()
            self.assertEqual(result.returncode, 1)
            self.assertIn('docs/worker.md step 4', report['next_step'])
            self.assertIn('capture init', report['next_step'])


class PinAndHintTests(unittest.TestCase):
    def test_pin_keeps_other_settings_and_permissions(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            env.cli('init', '--account', 'person@fictional.test')
            before = json.loads(env.config.read_text())
            result = env.cli('pin', '--folder-id', FOLDER)
            self.assertEqual(result.returncode, 0, result.stderr)
            after = json.loads(env.config.read_text())
            self.assertEqual(after.pop('folder_id'), FOLDER)
            before.pop('folder_id')
            self.assertEqual(after, before)
            self.assertEqual(stat.S_IMODE(env.config.stat().st_mode), 0o600)

    def test_pin_rejects_anything_but_a_drive_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            env.cli('init', '--account', 'person@fictional.test')
            for bad in ('../x', 'https://drive.google.com/x', 'a b', '', 'abc123'):
                result = env.cli('pin', '--folder-id', bad)
                self.assertEqual(result.returncode, 1, bad)
                self.assertEqual(json.loads(result.stdout)['error'], 'invalid_drive_id')
            self.assertEqual(json.loads(env.config.read_text())['folder_id'], '')

    def test_pin_rejects_the_placeholder_from_the_docs(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            env.cli('init', '--account', 'person@fictional.test')
            for placeholder in ('PASTE-THE-FOLDER-ID', 'FOLDER_ID'):
                result = env.cli('pin', '--folder-id', placeholder)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(json.loads(result.stdout)['error'], 'placeholder_drive_id')
            self.assertEqual(json.loads(env.config.read_text())['folder_id'], '')

    def test_pin_takes_the_id_out_of_a_drive_folder_link(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            env.cli('init', '--account', 'person@fictional.test')
            for link in (f'https://drive.google.com/drive/folders/{FOLDER}',
                         f'https://drive.google.com/drive/u/0/folders/{FOLDER}?usp=sharing'):
                result = env.cli('pin', '--folder-id', link)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(json.loads(result.stdout)['folder_id'], FOLDER)

    def test_probe_hint_explains_how_to_pin(self):
        config_path = Path(os.path.expanduser('~/Library/Application Support/Captura/config.json'))
        result = dict(state='private_inbox_verified', folder_id=FOLDER, errors=[])
        advice = onboarding.hint(result, config_path, dict(folder_id='', remote='captura'), 'bin/capture')
        self.assertIn('Copiar ID de carpeta', advice['note'])
        self.assertEqual(advice['next_step'], 'python3 bin/capture pin --config '
                         f'"$HOME/Library/Application Support/Captura/config.json" --folder-id {FOLDER}')
        pinned = onboarding.hint(result, config_path, dict(folder_id=FOLDER), 'bin/capture')
        self.assertIn(' run --config ', pinned['next_step'])
        self.assertNotIn(' pin ', pinned['next_step'])

    def test_invisible_phone_folder_suggests_readonly_fallback(self):
        config = dict(folder_id='', remote='captura', expected_account='person@fictional.test')
        for result in (dict(state='waiting_for_phone_folder', errors=[]),
                       dict(state='error', errors=['drive_http_404'])):
            advice = onboarding.hint(result, Path('/fictional/config.json'), config, 'bin/capture')
            self.assertIn('scope=drive.readonly', advice['next_step'])
        mismatch = onboarding.hint(dict(state='error', errors=['drive_account_mismatch']),
                                   Path('/fictional/config.json'), config, 'bin/capture')
        self.assertEqual(mismatch['next_step'], 'rclone config reconnect captura:')

    def test_probe_without_config_suggests_init(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            result = env.cli('probe', '--config', str(Path(tmp) / 'missing.json'))
            self.assertEqual(result.returncode, 1)
            failure = json.loads(result.stderr)
            self.assertEqual(failure['error'], 'capture_failed')
            self.assertIn('docs/worker.md step 4', failure['next_step'])
            self.assertIn('missing.json', failure['note'])

    def test_probe_without_rclone_remote_points_to_step_3_not_reconnect(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            env.cli('init', '--account', 'person@fictional.test')
            result = env.cli('probe')  # Same default --config as init, doctor and pin.
            report = json.loads(result.stdout)
            self.assertEqual(report['errors'], ['existing_drive_authorization_unavailable'])
            self.assertEqual(report['next_step'], onboarding.STEP_3)
            self.assertNotIn('reconnect', result.stdout)
            self.assertNotIn('capture doctor', result.stdout)
            self.assertRegex(report['at'], r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$')

    def test_expired_authorization_points_to_reconnect(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            env.cli('init', '--account', 'person@fictional.test')
            env.remote(rclone_section())  # Token expired; the fake rclone refreshes nothing.
            report = json.loads(env.cli('run').stdout)
            self.assertEqual(report['errors'], ['existing_drive_authorization_expired'])
            self.assertEqual(report['next_step'], 'rclone config reconnect captura:')
            self.assertIn('person@fictional.test', report['note'])

    def test_missing_inbox_suggests_running_the_worker(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            result = env.cli('list', '--root', str(Path(tmp) / 'no-inbox'))
            self.assertEqual(result.returncode, 1)
            failure = json.loads(result.stderr)
            self.assertEqual(failure['error'], 'inbox_not_found')
            self.assertTrue(failure['next_step'].endswith(' run'), failure)


class HelpTests(unittest.TestCase):
    def test_every_command_has_help(self):
        result = subprocess.run([sys.executable, CLI, '--help'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        for name in ('init', 'set', 'doctor', 'probe', 'pin', 'run', 'list', 'read', 'view'):
            with self.subTest(command=name):
                self.assertRegex(result.stdout, rf'\n\s+{name}\s+\S')
                sub = subprocess.run([sys.executable, CLI, name, '--help'], capture_output=True, text=True)
                self.assertEqual(sub.returncode, 0)
                self.assertIn('usage: python3 bin/capture ' + name, sub.stdout)


if __name__ == '__main__':
    unittest.main()
