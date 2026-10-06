"""Local setup helpers for the worker: `capture init`, `doctor`, `pin` and next-step hints.

No network. Never prints OAuth tokens or client secrets: from the rclone configuration
only the section's existence, `type`, `scope` and whether a client ID/token is present
are read out.
"""
import configparser
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

from worker import SafeError, identifier, load_config

DEFAULT_DIR = '~/Library/Application Support/Captura'
DEFAULT_CONFIG = DEFAULT_DIR + '/config.json'
DEFAULT_REMOTE = 'captura'
DEFAULT_MODEL = '~/.cache/whisper/ggml-large-v3-turbo.bin'
DEFAULT_VAD = '~/.cache/whisper/ggml-silero-v6.2.0.bin'
MIN_PYTHON = (3, 9)
# Exact sizes of the files the docs tell you to download (Hugging Face, ggml-org).
KNOWN_SIZES = {
    'ggml-large-v3-turbo.bin': 1624555275,
    'ggml-small.bin': 487601967,
    'ggml-silero-v6.2.0.bin': 885098,
}
MODEL_URLS = {
    'ggml-large-v3-turbo.bin': 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin',
    'ggml-small.bin': 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin',
    'ggml-silero-v6.2.0.bin': 'https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin',
}
OK, WARN, FAIL = 'ok', 'warn', 'fail'


def _home_relative(path):
    """A path under $HOME becomes `~/...`, so the config reads the same on any Mac."""
    path = str(path)
    home = os.path.expanduser('~')
    if path == home or path.startswith(home.rstrip('/') + '/'):
        return '~' + path[len(home.rstrip('/')):]
    return path


def default_rclone_config():
    """rclone's own default location, without running rclone."""
    if os.environ.get('RCLONE_CONFIG'):
        return _home_relative(os.environ['RCLONE_CONFIG'])
    base = os.environ.get('XDG_CONFIG_HOME') or os.path.expanduser('~/.config')
    return _home_relative(os.path.join(base, 'rclone', 'rclone.conf'))


def _tool(name):
    # Absolute paths survive launchd's short PATH; fall back to the bare name.
    return shutil.which(name) or name


def shell_path(path):
    """A path to paste into Terminal: `"$HOME/Library/Application Support/..."`."""
    path = os.path.expanduser(str(path))
    home = os.path.expanduser('~').rstrip('/')
    if path == home or path.startswith(home + '/'):
        rest = path[len(home):]
        return '"$HOME' + re.sub(r'(["\\$`])', r'\\\1', rest) + '"'
    return shlex.quote(path)


def command(prog, *parts):
    """A runnable command line. Path objects are shown relative to $HOME."""
    words = ['python3', shlex.quote(prog)]
    for part in parts:
        words.append(shell_path(part) if isinstance(part, Path) else shlex.quote(str(part)))
    return ' '.join(words)


def _write_private_json(path, data, replace):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    text = json.dumps(data, ensure_ascii=False, indent=2) + '\n'
    if not replace:
        # O_EXCL: never clobber a config that appeared meanwhile.
        handle = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(handle, 'w', encoding='utf-8') as stream:
            stream.write(text)
        return
    handle, temp = tempfile.mkstemp(prefix='.config-', suffix='.json', dir=path.parent)
    try:
        with os.fdopen(handle, 'w', encoding='utf-8') as stream:
            stream.write(text)
        os.chmod(temp, 0o600)
        os.replace(temp, path)
    except BaseException:
        if os.path.exists(temp):
            os.unlink(temp)
        raise


def _valid_account(value):
    return (isinstance(value, str) and re.fullmatch(r'[^@\s]+@[^@\s]+\.[^@\s]+', value)
            and not value.lower().endswith(('@example.com', '.example.com', '@example.org')))


def init_config(path, account, prog, remote=DEFAULT_REMOTE, model=DEFAULT_MODEL, force=False):
    path = Path(os.path.expanduser(path))
    if not _valid_account(account):
        return dict(state='error', error='invalid_account',
                    next_step='Pass the Google account the phone links, e.g. --account you@yourdomain.com')
    if not re.fullmatch(r'[A-Za-z0-9_. +@-]{1,64}', remote or ''):
        return dict(state='error', error='invalid_remote', next_step='Use a simple rclone remote name, e.g. captura')
    if path.exists() and not force:
        return dict(state='error', error='config_exists', config=str(path),
                    next_step='Keep it and run ' + command(prog, 'doctor', '--config', path)
                    + ', or replace it (the pinned folder_id is lost) with --force.')
    config = dict(
        root=DEFAULT_DIR + '/inbox',
        expected_account=account,
        remote=remote,
        rclone_config=default_rclone_config(),
        rclone=_tool('rclone'),
        folder_id='',
        quota_project=None,
        ffmpeg=_tool('ffmpeg'),
        whisper=_tool('whisper-cli'),
        model=model,
        vad_model=DEFAULT_VAD,
        language='es',
        transcribe=True,
    )
    _write_private_json(path, config, replace=force)
    return dict(state='config_written', config=str(path), settings=config,
                next_step=command(prog, 'doctor', '--config', path))


def pin_folder(path, folder_id, prog):
    path = Path(os.path.expanduser(path))
    try:
        folder_id = identifier((folder_id or '').strip())
    except SafeError:
        return dict(state='error', error='invalid_drive_id',
                    next_step='Paste the folder ID exactly as the phone or probe shows it.')
    if not path.is_file():
        return dict(state='error', error='config_not_found',
                    next_step=command(prog, 'init', '--account', 'you@yourdomain.com'))
    config = json.loads(path.read_text(encoding='utf-8'))
    previous = config.get('folder_id') or None
    config['folder_id'] = folder_id
    _write_private_json(path, config, replace=True)
    return dict(state='folder_pinned', config=str(path), folder_id=folder_id,
                previous_folder_id=previous,
                next_step=command(prog, 'run', '--config', path))


def _run(cmd, timeout=30):
    try:
        return subprocess.run(cmd, capture_output=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return None


def _executable(value):
    if not isinstance(value, str) or not value:
        return None
    if os.sep in value:
        path = os.path.expanduser(value)
        return path if os.path.isfile(path) and os.access(path, os.X_OK) else None
    return shutil.which(value)


def _check_tool(checks, name, value, install):
    path = _executable(value)
    if not path:
        checks.append(dict(check=name, status=FAIL, detail=f'{value!s} not found',
                           next_step=install))
        return None
    checks.append(dict(check=name, status=OK, detail=path))
    return path


def _check_model(checks, name, value, minimum, maximum=None):
    path = Path(os.path.expanduser(value or ''))
    fetch = MODEL_URLS.get(path.name)
    download = (f'curl -L --fail -o {shell_path(path)} {fetch}' if fetch
                else 'Download the model file again (see docs/worker.md).')
    if not value or not path.is_file():
        checks.append(dict(check=name, status=FAIL, detail=f'{_home_relative(path)} not found',
                           next_step='mkdir -p ' + shell_path(path.parent) + ' && ' + download))
        return
    size = path.stat().st_size
    with path.open('rb') as stream:
        head = stream.read(64).lstrip()
    expected = KNOWN_SIZES.get(path.name)
    human = f'{size / 1e6:,.1f} MB'
    if head[:1] == b'<' or head.startswith((b'Entry not found', b'{"error"', b'Not Found')):
        checks.append(dict(check=name, status=FAIL, detail='the file is a web page, not a model',
                           next_step='Delete it and download again: ' + download))
    elif expected and size < expected:
        checks.append(dict(check=name, status=FAIL,
                           detail=f'incomplete download ({human} of {expected / 1e6:,.1f} MB)',
                           next_step='Download it again: ' + download))
    elif expected and size != expected:
        checks.append(dict(check=name, status=WARN, detail=f'{human}, not the expected size',
                           next_step='If transcription fails, download it again: ' + download))
    elif size < minimum or (maximum and size > maximum):
        checks.append(dict(check=name, status=FAIL, detail=f'{human} is not a plausible size',
                           next_step='Download it again (see docs/worker.md).'))
    else:
        checks.append(dict(check=name, status=OK, detail=f'{_home_relative(path)} ({human})'))


def _check_rclone_remote(checks, config, prog):
    conf = Path(os.path.expanduser(config.get('rclone_config', '')))
    remote = config.get('remote', '')
    create = (f'rclone config create {shlex.quote(remote)} drive client_id=YOUR-DESKTOP-CLIENT-ID '
              'client_secret=YOUR-DESKTOP-CLIENT-SECRET scope=drive.file (see docs/worker.md)')
    if not conf.is_file():
        checks.append(dict(check='rclone_remote', status=FAIL,
                           detail=f'{_home_relative(conf)} does not exist', next_step=create))
        return
    raw = conf.read_text(encoding='utf-8', errors='replace')
    if raw.lstrip().startswith('# Encrypted rclone configuration') or 'RCLONE_ENCRYPT_V0:' in raw:
        checks.append(dict(check='rclone_remote', status=FAIL,
                           detail='the rclone configuration is encrypted; the worker cannot read it',
                           next_step='Keep the Captura remote in an unencrypted rclone config file '
                                     '(rclone config encryption remove), protected by your Mac login.'))
        return
    parser = configparser.RawConfigParser(strict=False, interpolation=None)
    try:
        parser.read_string(raw)
    except configparser.Error:
        checks.append(dict(check='rclone_remote', status=FAIL, detail='the rclone config cannot be parsed',
                           next_step='Run rclone config and fix or recreate the remote.'))
        return
    if not parser.has_section(remote):
        checks.append(dict(check='rclone_remote', status=FAIL,
                           detail=f'no remote named "{remote}" in {_home_relative(conf)}', next_step=create))
        return
    section = parser[remote]
    kind = section.get('type', '')
    if kind != 'drive':
        checks.append(dict(check='rclone_remote', status=FAIL, detail=f'"{remote}" has type "{kind}", not drive',
                           next_step=create))
        return
    scope = section.get('scope', '').strip()
    has_client = bool(section.get('client_id', '').strip())
    has_token = bool(section.get('token', '').strip())
    detail = f'"{remote}" is a Google Drive remote, scope {scope or "drive (rclone default: full access)"}'
    if not has_token:
        checks.append(dict(check='rclone_remote', status=FAIL, detail=detail + ', not authorized yet',
                           next_step=f'rclone config reconnect {shlex.quote(remote)}: (opens the browser; '
                                     'sign in with ' + str(config.get('expected_account')) + ')'))
        return
    if not has_client:
        checks.append(dict(check='rclone_remote', status=WARN,
                           detail=detail + ", using rclone's shared Google client",
                           next_step="rclone is retiring its shared client during 2026. Recreate the remote "
                                     "with your own Desktop OAuth client: " + create))
        return
    scopes = {s.strip() for s in scope.split(',') if s.strip()}
    if not scopes or 'drive' in scopes:
        checks.append(dict(check='rclone_remote', status=WARN, detail=detail,
                           next_step='Full Drive access is more than the worker needs. Recreate the remote '
                                     'with scope=drive.file, or scope=drive.readonly if probe cannot see '
                                     "the phone's folder."))
        return
    checks.append(dict(check='rclone_remote', status=OK, detail=detail + ', authorized'))


def doctor(path, prog):
    checks = []
    shown = Path(os.path.expanduser(path))
    version = sys.version_info
    if version[:2] < MIN_PYTHON:
        checks.append(dict(check='python', status=FAIL, detail=f'Python {version[0]}.{version[1]}',
                           next_step='Install Xcode (its python3 works) or brew install python.'))
    else:
        checks.append(dict(check='python', status=OK, detail=f'Python {version[0]}.{version[1]}.{version[2]}'))
    if not shown.is_file():
        checks.append(dict(check='config', status=FAIL, detail=f'{shown} does not exist',
                           next_step=command(prog, 'init', '--account', 'you@yourdomain.com')))
        return _summary(checks, shown, prog, None)
    try:
        config = load_config(shown)
    except SafeError as error:
        checks.append(dict(check='config', status=FAIL, detail=str(error),
                           next_step=f'Fix that value in {shown}, or recreate it with init --force.'))
        return _summary(checks, shown, prog, None)
    except (ValueError, OSError):
        checks.append(dict(check='config', status=FAIL, detail='not valid JSON',
                           next_step=f'Fix {shown}, or recreate it with init --force.'))
        return _summary(checks, shown, prog, None)
    mode = shown.stat().st_mode & 0o777
    if mode & 0o077:
        checks.append(dict(check='config', status=WARN, detail=f'readable by other users ({oct(mode)})',
                           next_step='chmod 600 ' + shell_path(shown)))
    else:
        checks.append(dict(check='config', status=OK, detail=_home_relative(shown)))
    if not _valid_account(config.get('expected_account')):
        checks.append(dict(check='account', status=FAIL, detail='expected_account is not a real address',
                           next_step=f'Set "expected_account" in {shown} to the Google account the phone links.'))
    else:
        checks.append(dict(check='account', status=OK, detail=config['expected_account']))
    if not re.fullmatch(r'[a-z]{2,3}|auto', str(config.get('language', 'es'))):
        checks.append(dict(check='language', status=FAIL, detail=str(config.get('language')),
                           next_step='Use a two-letter code such as "es", or "auto".'))
    _check_tool(checks, 'ffmpeg', config.get('ffmpeg', 'ffmpeg'), 'brew install ffmpeg')
    whisper = _check_tool(checks, 'whisper_cli', config.get('whisper', 'whisper-cli'), 'brew install whisper.cpp')
    if whisper:
        result = _run([whisper, '--help'])
        help_text = ((result.stdout or b'') + (result.stderr or b'')).decode('utf-8', 'replace') if result else ''
        if '--vad' not in help_text or '--vad-model' not in help_text:
            checks.append(dict(check='whisper_vad', status=FAIL,
                               detail='this whisper-cli does not list --vad/--vad-model',
                               next_step='brew upgrade whisper.cpp'))
        else:
            checks.append(dict(check='whisper_vad', status=OK, detail='whisper-cli supports --vad'))
    _check_model(checks, 'model', config.get('model'), minimum=25 * 1000 * 1000)
    _check_model(checks, 'vad_model', config.get('vad_model'), minimum=100 * 1000, maximum=100 * 1000 * 1000)
    if not config.get('transcribe', False):
        checks.append(dict(check='transcribe', status=WARN, detail='transcription is off',
                           next_step=f'Set "transcribe": true in {shown} to get text, not only audio.'))
    if _check_tool(checks, 'rclone', config.get('rclone', 'rclone'), 'brew install rclone'):
        _check_rclone_remote(checks, config, prog)
    folder = config.get('folder_id') or ''
    if folder:
        try:
            identifier(folder)
            checks.append(dict(check='folder_id', status=OK, detail=f'pinned: {folder}'))
        except SafeError:
            checks.append(dict(check='folder_id', status=FAIL, detail='not a Drive folder ID',
                               next_step=command(prog, 'pin', '--config', shown, '--folder-id', 'FOLDER_ID')))
    else:
        checks.append(dict(check='folder_id', status=WARN, detail='not pinned yet (run never imports without it)',
                           next_step=command(prog, 'probe', '--config', shown)))
    root = Path(config['root'])
    existing = root
    while not existing.exists() and existing != existing.parent:
        existing = existing.parent
    if root.exists() and not root.is_dir():
        checks.append(dict(check='root', status=FAIL, detail=f'{root} is not a folder',
                           next_step=f'Point "root" in {shown} to a folder.'))
    elif os.access(existing, os.W_OK | os.X_OK) and existing.is_dir():
        checks.append(dict(check='root', status=OK,
                           detail=f'{_home_relative(root)}' + ('' if root.exists() else ' (created on first run)')))
    else:
        checks.append(dict(check='root', status=FAIL, detail=f'{root} is not writable',
                           next_step=f'Point "root" in {shown} to a folder you own.'))
    return _summary(checks, shown, prog, config)


def _summary(checks, path, prog, config):
    failed = [c for c in checks if c['status'] == FAIL]
    warned = [c for c in checks if c['status'] == WARN]
    if failed:
        state, next_step = 'blocked', failed[0]['next_step']
    else:
        state = 'ready_with_warnings' if warned else 'ready'
        pinned = bool(config and config.get('folder_id'))
        next_step = command(prog, 'run' if pinned else 'probe', '--config', path)
    return dict(state=state, config=str(path), checks=checks, next_step=next_step)


SCOPE_HINT = ('If the phone already shows a folder ID, rclone cannot see it: with scope=drive.file the '
              'grant may not be shared between the phone and desktop clients. Recreate the remote with '
              'scope=drive.readonly (docs/worker.md), then probe again.')


def hint(result, config_path, config, prog):
    """Plain next step for a probe/run result. Advice only; never changes the result."""
    state = result.get('state')
    errors = result.get('errors') or []
    folder = result.get('folder_id')
    pinned = bool(config and config.get('folder_id'))
    if state == 'private_inbox_verified' and not pinned:
        return (f'Compare this folder_id with the one the phone shows under Google Drive '
                f'("Copiar ID de carpeta"). If they match, pin it: '
                + command(prog, 'pin', '--config', config_path, '--folder-id', folder)
                + ' and then run: ' + command(prog, 'run', '--config', config_path))
    if state == 'private_inbox_verified':
        return 'Folder pinned and verified. Next: ' + command(prog, 'run', '--config', config_path)
    if state == 'waiting_for_exact_folder_configuration':
        return ('Pin the folder after checking it matches the phone: '
                + command(prog, 'pin', '--config', config_path, '--folder-id', folder or 'FOLDER_ID'))
    if state == 'waiting_for_phone_folder':
        return ('No Captura folder is visible in this Drive yet. On the phone, link Google Drive with '
                f'{config.get("expected_account") if config else "the expected account"} and wait for '
                '"Copiar ID de carpeta". ' + SCOPE_HINT)
    code = errors[0] if errors else ''
    hints = {
        'drive_account_mismatch': 'rclone is signed in to a different Google account than expected_account. '
                                  'Fix expected_account, or run rclone config reconnect REMOTE: with the right account.',
        'existing_drive_authorization_unavailable': 'rclone has no usable authorization. Run: rclone config '
                                                    'reconnect REMOTE: (then: capture doctor).',
        'existing_drive_authorization_expired': 'Run: rclone config reconnect REMOTE: and sign in again.',
        'remote_not_drive': 'The configured remote is not Google Drive. Run capture doctor.',
        'ambiguous_capture_folders': 'More than one Captura folder exists. Pin the one the phone shows: '
                                     + command(prog, 'pin', '--config', config_path, '--folder-id', 'FOLDER_ID'),
        'wrong_folder': 'Drive returned a different folder. Check the pinned folder_id against the phone.',
        'folder_not_private_capture': 'That folder is shared, trashed or not created by the phone. Pin the ID the '
                                      'phone shows, and do not share that folder.',
        'drive_http_404': 'Drive cannot find the pinned folder for this rclone remote. ' + SCOPE_HINT,
        'drive_http_403': 'Drive refused access. ' + SCOPE_HINT,
        'drive_rate_limit_retry_later': 'Google asked to slow down. Try again in a few minutes.',
        'drive_connection_failed': 'No connection to Google Drive. Check the internet connection and try again.',
        'vad_model_required': 'The VAD model is missing. Run capture doctor.',
        'worker_already_running': 'Another run is still working. Wait for it to finish.',
    }
    if code in hints:
        return hints[code].replace('REMOTE', (config or {}).get('remote', 'captura'))
    if state == 'error' or errors:
        return 'Run ' + command(prog, 'doctor', '--config', config_path) + ' to see what is missing.'
    return None
