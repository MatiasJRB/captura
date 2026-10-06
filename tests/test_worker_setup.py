"""capture init / doctor / pin and next-step hints. Fake tools only, temp dirs, no network."""
import json
import os
from pathlib import Path
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
            env.cli('pin', '--folder-id', 'fictionalFolder_1')
            again = env.cli('init', '--account', 'other@fictional.test')
            self.assertEqual(again.returncode, 1)
            self.assertEqual(json.loads(again.stdout)['error'], 'config_exists')
            self.assertEqual(json.loads(env.config.read_text())['folder_id'], 'fictionalFolder_1')
            forced = env.cli('init', '--account', 'other@fictional.test', '--force')
            self.assertEqual(forced.returncode, 0, forced.stderr)
            config = json.loads(env.config.read_text())
            self.assertEqual((config['expected_account'], config['folder_id']), ('other@fictional.test', ''))
            self.assertEqual(stat.S_IMODE(env.config.stat().st_mode), 0o600)

    def test_init_rejects_placeholder_account(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            result = env.cli('init', '--account', 'you@example.com')
            self.assertEqual(result.returncode, 1)
            self.assertFalse(env.config.exists())


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
            env.cli('pin', '--folder-id', 'fictionalFolder_1')
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
            self.assertIn('rclone config create captura drive', checks['rclone_remote']['next_step'])
            self.assertEqual(report['next_step'], 'brew install ffmpeg')

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
        cases = [
            (rclone_section(name='other'), 'fail', 'no remote named "captura"'),
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
            self.assertIn(' init --account ', report['next_step'])


class PinAndHintTests(unittest.TestCase):
    def test_pin_keeps_other_settings_and_permissions(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            env.cli('init', '--account', 'person@fictional.test')
            before = json.loads(env.config.read_text())
            result = env.cli('pin', '--folder-id', 'fictionalFolder_1')
            self.assertEqual(result.returncode, 0, result.stderr)
            after = json.loads(env.config.read_text())
            self.assertEqual(after.pop('folder_id'), 'fictionalFolder_1')
            before.pop('folder_id')
            self.assertEqual(after, before)
            self.assertEqual(stat.S_IMODE(env.config.stat().st_mode), 0o600)

    def test_pin_rejects_anything_but_a_drive_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            env.cli('init', '--account', 'person@fictional.test')
            for bad in ('../x', 'https://drive.google.com/x', 'a b', ''):
                result = env.cli('pin', '--folder-id', bad)
                self.assertEqual(result.returncode, 1, bad)
            self.assertEqual(json.loads(env.config.read_text())['folder_id'], '')

    def test_probe_hint_explains_how_to_pin(self):
        config_path = Path(os.path.expanduser('~/Library/Application Support/Captura/config.json'))
        result = dict(state='private_inbox_verified', folder_id='fictionalFolder_1', errors=[])
        text = onboarding.hint(result, config_path, dict(folder_id='', remote='captura'), 'bin/capture')
        self.assertIn('Copiar ID de carpeta', text)
        self.assertIn('python3 bin/capture pin --config "$HOME/Library/Application Support/Captura/config.json" '
                      '--folder-id fictionalFolder_1', text)
        pinned = onboarding.hint(result, config_path, dict(folder_id='fictionalFolder_1'), 'bin/capture')
        self.assertIn(' run --config ', pinned)
        self.assertNotIn(' pin ', pinned)

    def test_invisible_phone_folder_suggests_readonly_fallback(self):
        config = dict(folder_id='', remote='captura', expected_account='person@fictional.test')
        for result in (dict(state='waiting_for_phone_folder', errors=[]),
                       dict(state='error', errors=['drive_http_404'])):
            text = onboarding.hint(result, Path('/fictional/config.json'), config, 'bin/capture')
            self.assertIn('scope=drive.readonly', text)
        mismatch = onboarding.hint(dict(state='error', errors=['drive_account_mismatch']),
                                   Path('/fictional/config.json'), config, 'bin/capture')
        self.assertIn('rclone config reconnect captura:', mismatch)

    def test_probe_without_config_suggests_init(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = SetupHome(tmp)
            result = env.cli('probe', '--config', str(Path(tmp) / 'missing.json'))
            self.assertEqual(result.returncode, 1)
            failure = json.loads(result.stderr)
            self.assertEqual(failure['error'], 'capture_failed')
            self.assertIn(' init --config ', failure['next_step'])


if __name__ == '__main__':
    unittest.main()
