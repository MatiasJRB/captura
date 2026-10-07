"""Local setup helpers for the worker: `capture init`, `set`, `doctor`, `pin` and hints.

No network. Never prints OAuth tokens or client secrets: from the rclone configuration
only the section's existence, `type`, `scope`, the shape of the client ID and whether a
token is present are read out.

Advice fields: `next_step` is either one shell command or prose without a command in
it, so it can be pasted as it is. `note` adds context in prose. `alternative` is another
command or prose. `plain_advice()` renders them as text for a person at a terminal: each
`Next:`, `Or:` or `Fix:` line holds one command or one sentence, and the prose around it
goes on lines of its own, so copying a whole line never pastes a sentence into the shell.
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

from worker import SafeError, load_config

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
    'ggml-large-v3-turbo-q5_0.bin':
        'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin',
    'ggml-small.bin': 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin',
    'ggml-silero-v6.2.0.bin': 'https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin',
}
# The model docs/worker.md step 2 downloads, then its smaller fallbacks, best first.
RECOMMENDED_MODELS = ('ggml-large-v3-turbo.bin', 'ggml-large-v3-turbo-q5_0.bin', 'ggml-small.bin')
LOW_ACCURACY_MODELS = ('tiny', 'base')
OK, WARN, FAIL = 'ok', 'warn', 'fail'
# What each doctor check is about, for people; the JSON keeps the check IDs for agents.
LABELS = {
    'python': 'Python',
    'config': 'the worker settings (step 4)',
    'account': 'the Google account in the settings (step 4)',
    'language': 'the transcription language (step 4)',
    'ffmpeg': 'ffmpeg (step 1)',
    'whisper_cli': 'whisper-cli (step 1)',
    'whisper_vad': "whisper-cli's voice detection (step 1)",
    'model': 'the speech model (step 2)',
    'vad_model': 'the voice detection model (step 2)',
    'transcribe': 'transcription',
    'rclone': 'rclone (step 1)',
    'rclone_remote': 'the rclone connection to Google Drive (step 3)',
    'folder_id': "the phone's Drive folder (steps 6 and 7)",
    'root': 'the transcripts folder (step 4)',
}
LANGUAGE = re.compile(r'[a-z]{2,3}|auto')
REMOTE_NAME = re.compile(r'[A-Za-z0-9_. +@-]{1,64}')
STEP_3 = 'Do step 3 of docs/worker.md (Connect rclone to Google Drive).'
STEP_4 = 'Create the worker config first: docs/worker.md step 4 (capture init with the Google account the phone links).'
# What the docs and messages use as stand-ins; never a real Drive folder ID.
PLACEHOLDER_WORDS = ('paste', 'folder', 'example')
FOLDER_LINK = re.compile(r'https?://drive\.google\.com/(?:drive/(?:u/\d+/)?folders/|open\?id=)([A-Za-z0-9_-]+)')


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
    if not isinstance(value, str) or not re.fullmatch(r'[^@\s]+@[^@\s]+\.[^@\s]+', value):
        return False
    domain = value.lower().rsplit('@', 1)[1]
    # Stand-ins from the docs (you@yourcompany.com) would pin the worker to nobody.
    return not any(word in domain for word in ('example', 'yourcompany', 'yourdomain'))


def folder_id_from(value):
    """The Drive folder ID in what the person pasted: the ID itself or a Drive folder link."""
    text = (value or '').strip().strip('"\'').strip()
    link = FOLDER_LINK.match(text)
    if link:
        text = link.group(1)
    if any(word in text.lower() for word in PLACEHOLDER_WORDS):
        raise SafeError('placeholder_drive_id')
    # Drive IDs are long random strings (folders made by the phone have 33 characters).
    if not re.fullmatch(r'[A-Za-z0-9_-]{19,200}', text):
        raise SafeError('invalid_drive_id')
    return text


def _user_path(value):
    """An absolute path as the config stores it (`~/...` under the home folder)."""
    return _home_relative(os.path.abspath(os.path.expanduser(value)))


ACCOUNT_PLACEHOLDER = 'YOUR-GOOGLE-ADDRESS'
ACCOUNT_NOTE = ('Use the Google account you link on the phone (after linking, iPhone step 10.2 shows it under '
                '"Cuenta"). The address in the guide is only an example.')


def _settings_error(account=None, remote=None, language=None, retry=None):
    """The first invalid value as an error result, or None. `retry(*parts)` is the command
    to run again with an account placeholder."""
    if account is not None and not _valid_account(account):
        return dict(state='error', error='invalid_account', note=ACCOUNT_NOTE,
                    next_step=retry('--account', ACCOUNT_PLACEHOLDER) if retry else ACCOUNT_NOTE)
    if remote is not None and not REMOTE_NAME.fullmatch(remote):
        return dict(state='error', error='invalid_remote', next_step='Use a simple rclone remote name, such as captura.')
    if language is not None and not LANGUAGE.fullmatch(language):
        return dict(state='error', error='invalid_language',
                    next_step='Use a two- or three-letter language code such as es or en, or auto.')
    return None


def _retry(prog, name, path, **options):
    """`retry(*parts)`: the same `name` command with the options that were valid, plus `parts`."""
    def retry(*parts):
        words = [name]
        if Path(path) != Path(os.path.expanduser(DEFAULT_CONFIG)):
            words += ['--config', Path(path)]
        for key, value in options.items():
            if value is not None:
                words += ['--' + key, Path(os.path.expanduser(value)) if key in ('model', 'root') else value]
        return command(prog, *words, *parts)
    return retry


def init_config(path, account, prog, remote=None, model=None, force=False, root=None, language=None):
    """Writes a new config. Options left as None take the defaults."""
    path = Path(os.path.expanduser(path))
    retry = _retry(prog, 'init', path, remote=remote, model=model, root=root, language=language)
    error = _settings_error(account, remote, language, retry)
    if error:
        return error
    chosen = dict(remote=remote, model=model and _user_path(model), root=root and _user_path(root),
                  language=language)
    if path.exists() and not force:
        result = dict(state='error', error='config_exists', config=str(path),
                      next_step=command(prog, 'doctor', '--config', path),
                      note='A worker config already exists, so nothing was written. --force starts over and '
                           'clears the pinned folder (then redo docs/worker.md step 7).')
        try:
            current = json.loads(path.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            current = {}
        # Paths as Path objects, so the suggested command shows them as "$HOME/...".
        wanted = {key: Path(os.path.expanduser(value)) if key in ('model', 'root') else value
                  for key, value in chosen.items() if value is not None}
        if account != current.get('expected_account'):
            wanted['account'] = account
        changes = [part for key in ('account', 'remote', 'model', 'root', 'language') if key in wanted
                   for part in ('--' + key, wanted[key])]
        if changes:
            # They asked for new values: set applies just those and keeps the pinned folder.
            result['next_step'] = command(prog, 'set', '--config', path, *changes)
            result['note'] = ('A worker config already exists, so nothing was written. This changes only the '
                              'values you gave and keeps the pinned folder. --force would start over and clear '
                              'the pinned folder.')
        return result
    config = dict(
        root=chosen['root'] or DEFAULT_DIR + '/inbox',
        expected_account=account,
        remote=remote or DEFAULT_REMOTE,
        rclone_config=default_rclone_config(),
        rclone=_tool('rclone'),
        folder_id='',
        quota_project=None,
        ffmpeg=_tool('ffmpeg'),
        whisper=_tool('whisper-cli'),
        model=chosen['model'] or DEFAULT_MODEL,
        vad_model=DEFAULT_VAD,
        language=language or 'es',
        transcribe=True,
    )
    _write_private_json(path, config, replace=force)
    return dict(state='config_written', config=str(path), settings=config,
                next_step=command(prog, 'doctor', '--config', path))


def update_config(path, prog, account=None, remote=None, model=None, root=None, language=None):
    """Changes only the values given; keeps the pinned folder and every other setting."""
    path = Path(os.path.expanduser(path))
    retry = _retry(prog, 'set', path, remote=remote, model=model, root=root, language=language)
    error = _settings_error(account, remote, language, retry)
    if error:
        return error
    if not path.is_file():
        return dict(state='error', error='config_not_found', config=str(path), next_step=STEP_4)
    wanted = dict(expected_account=account, remote=remote, model=model and _user_path(model),
                  root=root and _user_path(root), language=language)
    wanted = {key: value for key, value in wanted.items() if value is not None}
    if not wanted:
        return dict(state='error', error='nothing_to_set',
                    next_step='Name what to change: --model, --root, --language, --account or --remote.')
    config = json.loads(path.read_text(encoding='utf-8'))
    changed = {key: dict(old=config.get(key), new=value) for key, value in wanted.items()
               if config.get(key) != value}
    config.update(wanted)
    _write_private_json(path, config, replace=True)
    result = dict(state='config_updated', config=str(path), changed=changed,
                  next_step=command(prog, 'doctor', '--config', path))
    if 'expected_account' in changed and config.get('folder_id'):
        result['note'] = ('The pinned folder belongs to the old account. Run probe and pin the new '
                          "account's folder (docs/worker.md steps 6 and 7).")
    return result


def pin_folder(path, folder_id, prog):
    path = Path(os.path.expanduser(path))
    try:
        folder_id = folder_id_from(folder_id)
    except SafeError as error:
        if str(error) == 'placeholder_drive_id':
            return dict(state='error', error='placeholder_drive_id',
                        next_step='Replace the placeholder with the real folder ID: tap "Copiar ID de carpeta" '
                                  'on the phone, or use the folder_id that probe printed.')
        return dict(state='error', error='invalid_drive_id',
                    next_step='Copy the folder ID again: tap "Copiar ID de carpeta" on the phone, or use the '
                              'folder_id that probe printed. A drive.google.com/drive/folders/ link works too.')
    if not path.is_file():
        return dict(state='error', error='config_not_found', next_step=STEP_4)
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


def _other_models(folder, missing):
    """Whisper models already in `folder`, best first, so doctor can offer them instead of a
    download: the ones docs/worker.md recommends in its order, then the rest, larger first."""
    try:
        sizes = {p.name: p.stat().st_size for p in Path(folder).glob('ggml-*.bin') if p.is_file()}
    except OSError:
        return []

    def rank(name):
        known = RECOMMENDED_MODELS.index(name) if name in RECOMMENDED_MODELS else len(RECOMMENDED_MODELS)
        return known, -sizes[name], name
    return sorted((n for n in sizes if n != missing and 'silero' not in n and 'vad' not in n), key=rank)


def _low_accuracy(name):
    return any(word in name for word in LOW_ACCURACY_MODELS)


def _check_model(checks, name, value, minimum, maximum=None, prog=None, config_path=None):
    path = Path(os.path.expanduser(value or ''))
    fetch = MODEL_URLS.get(path.name)
    # curl -o replaces a partial or wrong file, so the same command fixes every case.
    download = f'curl -L --fail -o {shell_path(path)} {fetch}' if fetch else None
    again = download or 'Download the model file again (docs/worker.md step 2).'
    if not value or not path.is_file():
        check = dict(check=name, status=FAIL, detail=f'{_home_relative(path)} not found',
                     next_step=('mkdir -p ' + shell_path(path.parent) + ' && ' + download) if download
                     else 'Download the model file (docs/worker.md step 2), or point the config at one you have.')
        others = _other_models(path.parent, path.name) if name == 'model' else []
        if others and prog:
            check['detail'] += f' (also in that folder: {", ".join(others)})'
            check['alternative'] = command(prog, 'set', '--config', config_path, '--model', path.parent / others[0])
            check['note'] = (f'Download {path.name} with the first command, or switch to {others[0]}, which is '
                             'already on this Mac, with the second.'
                             + (' It transcribes less accurately.' if _low_accuracy(others[0]) else ''))
        checks.append(check)
        return
    size = path.stat().st_size
    with path.open('rb') as stream:
        head = stream.read(64).lstrip()
    expected = KNOWN_SIZES.get(path.name)
    human = f'{size / 1e6:,.1f} MB'
    if head[:1] == b'<' or head.startswith((b'Entry not found', b'{"error"', b'Not Found')):
        checks.append(dict(check=name, status=FAIL, detail='the file is a web page, not a model',
                           next_step=again))
    elif expected and size < expected:
        checks.append(dict(check=name, status=FAIL,
                           detail=f'incomplete download ({human} of {expected / 1e6:,.1f} MB)',
                           next_step=again))
    elif expected and size != expected:
        checks.append(dict(check=name, status=WARN, detail=f'{human}, not the expected size',
                           next_step=again, note='Download it again only if transcription fails.'))
    elif size < minimum or (maximum and size > maximum):
        checks.append(dict(check=name, status=FAIL, detail=f'{human} is not a plausible size',
                           next_step=again))
    elif name == 'model' and _low_accuracy(path.name):
        checks.append(dict(check=name, status=WARN,
                           detail=f'{_home_relative(path)} ({human}) transcribes less accurately than the models '
                                  'in docs/worker.md step 2',
                           next_step='For better text, download ggml-large-v3-turbo.bin or ggml-small.bin (docs/'
                                     'worker.md step 2) and switch to it with set --model.'))
    else:
        checks.append(dict(check=name, status=OK, detail=f'{_home_relative(path)} ({human})'))


def inspect_remote(config):
    """The rclone remote as one check: {check, status, detail, next_step[, note]}.

    Reads only the section's type, scope, the client ID's shape and whether a token exists.
    """
    conf = Path(os.path.expanduser(config.get('rclone_config', '')))
    remote = config.get('remote', '')
    name = shlex.quote(remote)
    account = config.get('expected_account') or 'the account the phone links'
    recreate = (f'Remove it with "rclone config delete {remote}", then do step 3 of docs/worker.md '
                '(Connect rclone to Google Drive) again.')

    def result(status, detail, next_step=None, note=None):
        check = dict(check='rclone_remote', status=status, detail=detail)
        if next_step:
            check['next_step'] = next_step
        if note:
            check['note'] = note
        return check

    if not conf.is_file():
        return result(FAIL, f'{_home_relative(conf)} does not exist (no rclone remote yet)', STEP_3)
    raw = conf.read_text(encoding='utf-8', errors='replace')
    if raw.lstrip().startswith('# Encrypted rclone configuration') or 'RCLONE_ENCRYPT_V0:' in raw:
        return result(FAIL, 'the rclone configuration is encrypted; the worker cannot read it',
                      'Keep the Captura remote in an unencrypted rclone config file, protected by your Mac '
                      'login ("rclone config encryption remove" decrypts the current one).')
    parser = configparser.RawConfigParser(strict=False, interpolation=None)
    try:
        parser.read_string(raw)
    except configparser.Error:
        return result(FAIL, 'the rclone config cannot be parsed',
                      f'Fix {_home_relative(conf)} with "rclone config", or move it away and do step 3 '
                      'of docs/worker.md (Connect rclone to Google Drive).')
    if not parser.has_section(remote):
        return result(FAIL, f'no remote named "{remote}" in {_home_relative(conf)}', STEP_3)
    section = parser[remote]
    kind = section.get('type', '')
    if kind != 'drive':
        return result(FAIL, f'"{remote}" has type "{kind}", not drive', recreate)
    scope = section.get('scope', '').strip()
    client = section.get('client_id', '').strip()
    has_token = bool(section.get('token', '').strip())
    detail = f'"{remote}" is a Google Drive remote, scope {scope or "drive (rclone default: full access)"}'
    if client and not re.fullmatch(r'[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com', client):
        # A mistyped ID gets "invalid_client" or "OAuth client was not found" from Google.
        return result(FAIL, detail + ', but its client_id does not look like a Google client ID', recreate,
                      'Copy the Desktop client ID exactly; it ends in .apps.googleusercontent.com.')
    if not has_token:
        return result(FAIL, detail + ', not authorized yet', f'rclone config reconnect {name}:',
                      f'Sign in with {account} in the browser that opens.')
    problems = []
    if not client:
        problems.append("it uses rclone's shared Google client, which rclone is retiring during 2026")
    scopes = {s.strip() for s in scope.split(',') if s.strip()}
    if not scopes or 'drive' in scopes:
        problems.append('full Drive access is more than the worker needs')
    elif scopes - {'drive.file', 'drive.readonly'}:
        problems.append('the worker expects scope drive.file or drive.readonly')
    if problems:
        return result(WARN, detail + ', authorized, but ' + '; '.join(problems), recreate,
                      'Use the Desktop client from the admin and scope=drive.file, or scope=drive.readonly '
                      'if probe cannot see the phone\'s folder.')
    return result(OK, detail + ', authorized')


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
        checks.append(dict(check='config', status=FAIL, detail=f'{shown} does not exist', next_step=STEP_4))
        return _summary(checks, shown, prog, None)
    try:
        config = load_config(shown)
    except SafeError as error:
        checks.append(dict(check='config', status=FAIL, detail=str(error),
                           next_step=f'Fix that value in {shown}, or recreate the config with init --force '
                                     '(docs/worker.md step 4).'))
        return _summary(checks, shown, prog, None)
    except (ValueError, OSError):
        checks.append(dict(check='config', status=FAIL, detail='not valid JSON',
                           next_step=f'Fix {shown}, or recreate the config with init --force '
                                     '(docs/worker.md step 4).'))
        return _summary(checks, shown, prog, None)
    mode = shown.stat().st_mode & 0o777
    if mode & 0o077:
        checks.append(dict(check='config', status=WARN, detail=f'readable by other users ({oct(mode)})',
                           next_step='chmod 600 ' + shell_path(shown)))
    else:
        checks.append(dict(check='config', status=OK, detail=_home_relative(shown)))
    if not _valid_account(config.get('expected_account')):
        checks.append(dict(check='account', status=FAIL, detail='expected_account is not a real address',
                           next_step=command(prog, 'set', '--config', shown, '--account', ACCOUNT_PLACEHOLDER),
                           note=ACCOUNT_NOTE))
    else:
        checks.append(dict(check='account', status=OK, detail=config['expected_account']))
    if not LANGUAGE.fullmatch(str(config.get('language', 'es'))):
        checks.append(dict(check='language', status=FAIL, detail=str(config.get('language')),
                           next_step=command(prog, 'set', '--config', shown, '--language', 'es'),
                           note='Use a two-letter code such as es, or auto.'))
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
    _check_model(checks, 'model', config.get('model'), minimum=25 * 1000 * 1000, prog=prog, config_path=shown)
    _check_model(checks, 'vad_model', config.get('vad_model'), minimum=100 * 1000, maximum=100 * 1000 * 1000)
    if not config.get('transcribe', False):
        checks.append(dict(check='transcribe', status=WARN, detail='transcription is off',
                           next_step=f'Set "transcribe": true in {shown} to get text, not only audio.'))
    if _check_tool(checks, 'rclone', config.get('rclone', 'rclone'), 'brew install rclone'):
        checks.append(inspect_remote(config))
    folder = config.get('folder_id') or ''
    if folder:
        try:
            if folder_id_from(folder) != folder:
                raise SafeError('invalid_drive_id')
            checks.append(dict(check='folder_id', status=OK, detail=f'pinned: {folder}'))
        except SafeError:
            checks.append(dict(check='folder_id', status=FAIL, detail=f'"{folder}" is not a Drive folder ID',
                               next_step=command(prog, 'probe', '--config', shown),
                               note='Then pin the folder ID that probe and the phone show (docs/worker.md step 7).'))
    else:
        checks.append(dict(check='folder_id', status=WARN, detail='not pinned yet (run never imports without it)',
                           next_step=command(prog, 'probe', '--config', shown)))
    root = Path(config['root'])
    existing = root
    while not existing.exists() and existing != existing.parent:
        existing = existing.parent
    if root.exists() and not root.is_dir():
        checks.append(dict(check='root', status=FAIL, detail=f'{root} is not a folder',
                           next_step='Choose a folder for the transcripts with set --root '
                                     '(python3 bin/capture set --help).'))
    elif os.access(existing, os.W_OK | os.X_OK) and existing.is_dir():
        checks.append(dict(check='root', status=OK,
                           detail=f'{_home_relative(root)}' + ('' if root.exists() else ' (created on first run)')))
    else:
        checks.append(dict(check='root', status=FAIL, detail=f'{root} is not writable',
                           next_step='Choose a folder you own for the transcripts with set --root '
                                     '(python3 bin/capture set --help).'))
    return _summary(checks, shown, prog, config)


ADVICE = ('next_step', 'note', 'alternative')
# How the commands in advice start; anything else is a sentence.
COMMANDS = ('python3 ', 'curl ', 'mkdir ', 'rclone ', 'brew ', 'chmod ', 'git ')


def _summary(checks, path, prog, config):
    failed = [c for c in checks if c['status'] == FAIL]
    warned = [c for c in checks if c['status'] == WARN]
    result = dict(state='blocked' if failed else 'ready_with_warnings' if warned else 'ready',
                  config=str(path), checks=checks)
    if failed:
        result.update({key: failed[0][key] for key in ADVICE if key in failed[0]})
        if len(failed) > 1:
            result['also_failing'] = [c['check'] for c in failed[1:]]
    else:
        pinned = bool(config and config.get('folder_id'))
        result['next_step'] = command(prog, 'run' if pinned else 'probe', '--config', path)
    return result


SCOPE_HINT = ('If the phone already shows a folder ID, rclone cannot see it: with scope=drive.file the '
              'grant may not be shared between the phone and desktop clients. Recreate the remote with '
              'scope=drive.readonly (docs/worker.md step 3), then probe again.')


def _authorization_advice(config):
    """Tells "no remote yet" apart from "authorization expired or revoked"."""
    if not _executable((config or {}).get('rclone', 'rclone')):
        return dict(next_step='brew install rclone', note='rclone is not installed where the config says.')
    remote = inspect_remote(config or {})
    if remote['status'] == FAIL:
        advice = {key: remote[key] for key in ADVICE if key in remote}
        advice.setdefault('note', 'rclone has no usable authorization: ' + remote['detail'] + '.')
        return advice
    name = shlex.quote((config or {}).get('remote', DEFAULT_REMOTE))
    return dict(next_step=f'rclone config reconnect {name}:',
                note='rclone could not refresh its Google authorization: it expired or was revoked, '
                     'or there was no internet connection. Sign in with '
                     f'{(config or {}).get("expected_account", "the account the phone links")} in the browser that '
                     'opens, then run this command again.')


def hint(result, config_path, config, prog):
    """Advice for a probe/run result, as fields to add to it (see ADVICE). Never changes the result."""
    state = result.get('state')
    errors = result.get('errors') or []
    folder = result.get('folder_id')
    pinned = bool(config and config.get('folder_id'))
    remote = shlex.quote((config or {}).get('remote', DEFAULT_REMOTE))
    doctor = command(prog, 'doctor', '--config', config_path)
    compare = ('Before you run it, check that this folder_id matches the one the phone shows under '
               '"Copiar ID de carpeta".')
    if state == 'private_inbox_verified' and not pinned:
        return dict(next_step=command(prog, 'pin', '--config', config_path, '--folder-id', folder), note=compare)
    if state == 'private_inbox_verified':
        return dict(next_step=command(prog, 'run', '--config', config_path), note='Folder pinned and verified.')
    if state == 'waiting_for_exact_folder_configuration' and folder:
        return dict(next_step=command(prog, 'pin', '--config', config_path, '--folder-id', folder), note=compare)
    if state == 'waiting_for_phone_folder':
        return dict(next_step='No Captura folder is visible in this Drive yet. On the phone, link Google Drive with '
                              f'{config.get("expected_account") if config else "the expected account"} and wait '
                              'for "Copiar ID de carpeta". ' + SCOPE_HINT)
    code = errors[0] if errors else ''
    if code in ('existing_drive_authorization_unavailable', 'existing_drive_authorization_expired'):
        return _authorization_advice(config)
    hints = {
        'drive_account_mismatch': dict(
            next_step=f'rclone config reconnect {remote}:',
            note='rclone is signed in to a different Google account than expected_account '
                 f'({(config or {}).get("expected_account")}). Choose that account in the browser, or change '
                 'expected_account with set --account.'),
        'remote_not_drive': dict(next_step=doctor, note='The configured rclone remote is not Google Drive.'),
        'ambiguous_capture_folders': dict(
            next_step='More than one Captura folder exists in this Drive. Pin the one the phone shows under '
                      '"Copiar ID de carpeta" (docs/worker.md step 7).'),
        'wrong_folder': dict(next_step='Drive returned a different folder. Check the pinned folder_id against '
                                       'the phone (docs/worker.md step 7).'),
        'folder_not_private_capture': dict(
            next_step='That folder is shared, trashed or not created by the phone. Pin the ID the phone shows '
                      '(docs/worker.md step 7), and do not share that folder.'),
        'drive_http_404': dict(next_step='Drive cannot find the pinned folder for this rclone remote. ' + SCOPE_HINT),
        'drive_http_403': dict(next_step='Drive refused access. ' + SCOPE_HINT),
        'drive_rate_limit_retry_later': dict(next_step='Google asked to slow down. Try again in a few minutes.'),
        'drive_connection_failed': dict(next_step='No connection to Google Drive. Check the internet connection '
                                                  'and try again.'),
        'vad_model_required': dict(next_step=doctor, note='The VAD model is missing.'),
        'worker_already_running': dict(next_step='Another run is still working. Wait for it to finish.'),
    }
    if code in hints:
        return hints[code]
    if state == 'error' or errors:
        return dict(next_step=doctor, note='Doctor shows what is missing.')
    return {}


def label(check_id):
    return LABELS.get(check_id, check_id.replace('_', ' '))


def plain_advice(result):
    """The advice in `result` as plain lines for a person at a terminal: commands appear
    exactly as they must be typed, without JSON escaping, each alone after its label.

    Doctor's warnings come first (they are only in the JSON otherwise), then the note,
    then `Next:` and `Or:`, then what else fails, in words rather than check IDs. While
    something fails, warnings get no `Fix:` command yet: the failures come first."""
    lines = []
    shown = {result.get('next_step'), result.get('alternative')}
    for check in result.get('checks') or []:
        if check.get('status') != WARN:
            continue
        step, note = check.get('next_step'), check.get('note')
        command_step = bool(step) and step.startswith(COMMANDS)
        text = f'Warn: {label(check["check"])}: {check["detail"]}.'
        for prose in (None if command_step else step, note):
            if prose:
                text += ' ' + prose
        lines.append(text)
        if command_step and step not in shown and result.get('state') != 'blocked':
            lines.append('Fix:  ' + step)
    if result.get('note'):
        lines.append(result['note'])
    if result.get('next_step'):
        lines.append('Next: ' + result['next_step'])
    if result.get('alternative'):
        lines.append('Or:   ' + result['alternative'])
    if result.get('also_failing'):
        lines.append('Then fix: ' + ', '.join(label(c) for c in result['also_failing'])
                     + '. Run doctor again after each fix.')
    return lines
