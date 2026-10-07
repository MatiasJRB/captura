"""`capture drive-setup`: write the rclone remote the worker uses, then let rclone sign in.

The Desktop client ID and secret come from a password manager item (`--from`), one
reference each (`--client-id-ref`, `--client-secret-ref`) or a prompt (the secret without
echo). The secret goes straight into the rclone config file (mode 0600, atomic replace):
never on a command line, in the environment of a child process, in the output or in an
error. After that, `rclone config reconnect REMOTE:` runs in the person's terminal so they
sign in in the browser, and the result reports only non-secret facts about the remote.
"""
import configparser
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

import onboarding

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import secret_refs  # noqa: E402

SCOPES = ('drive.file', 'drive.readonly')
FIELD_KEYS = ('client_id', 'client_secret')
CLIENT_ID = re.compile(r'[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com')
# Printable ASCII without spaces, quotes, backslashes or the ini comment characters.
SECRET_SHAPE = re.compile(r'[A-Za-z0-9_.~+/=:@!$%&*(){}<>?^|,-]{8,512}')
SECRET_PLACEHOLDERS = ('paste', 'your-', 'yoursecret', 'client-secret', 'client_secret', 'example')
HEADER = re.compile(r'^\s*\[(.*)\]\s*$')


def _error(code, next_step, note=None, **extra):
    result = dict(state='error', error=code, next_step=next_step, **extra)
    if note:
        result['note'] = note
    return result


def _command(prog, config_path, *parts):
    """`python3 bin/capture drive-setup ...` with --config only when it is not the default."""
    return onboarding.drive_setup_command(prog, config_path, None, *parts)


def _rclone_command(rclone_conf, remote):
    """`rclone [--config PATH] config reconnect REMOTE:` as text for a person to paste."""
    words = ['rclone']
    if os.path.expanduser(rclone_conf) != os.path.expanduser(onboarding.default_rclone_config()):
        words += ['--config', onboarding.shell_path(rclone_conf)]
    return ' '.join(words + ['config', 'reconnect', shlex.quote(remote + ':')])


def check_client_id(value):
    value = (value or '').strip().strip('"\'').strip()
    if not value:
        return None, 'empty_client_id'
    if any(word in value.lower() for word in ('paste', 'example', 'your-')):
        return None, 'placeholder_client_id'
    if not CLIENT_ID.fullmatch(value):
        return None, 'invalid_client_id'
    number = value.split('-', 1)[0]
    if len(set(number)) == 1:
        return None, 'placeholder_client_id'
    return value, None


def check_secret(value):
    """(secret, None) or (None, error code). The code never says anything about the value."""
    value = (value or '').strip()
    if not value:
        return None, 'empty_client_secret'
    if any(word in value.lower() for word in SECRET_PLACEHOLDERS):
        return None, 'placeholder_client_secret'
    if not SECRET_SHAPE.fullmatch(value):
        return None, 'invalid_client_secret'
    return value, None


def render_section(remote, client_id, secret, scope):
    return (f'[{remote}]\ntype = drive\nclient_id = {client_id}\nclient_secret = {secret}\n'
            f'scope = {scope}\n')


def sections(text):
    """[(name, start_line, end_line)] of the ini sections in rclone.conf text."""
    lines = text.splitlines(keepends=True)
    found = []
    for index, line in enumerate(lines):
        match = HEADER.match(line)
        if match:
            if found:
                found[-1][2] = index
            found.append([match.group(1).strip(), index, len(lines)])
    return lines, [tuple(item) for item in found]


def replace_section(text, remote, section):
    """`text` with the section `remote` replaced by `section`, or `section` appended.
    Every other line of the file is kept as it was."""
    lines, found = sections(text)
    for name, start, end in found:
        if name == remote:
            # Keep the blank lines that separate it from the next section.
            tail = end
            while tail > start + 1 and not lines[tail - 1].strip():
                tail -= 1
            return ''.join(lines[:start]) + section + ''.join(lines[tail:end]) + ''.join(lines[end:])
    body = ''.join(lines)
    if body and not body.endswith('\n'):
        body += '\n'
    if body.strip():
        body += '\n'
    return body + section


def write_private(path, text):
    """Atomic replace with mode 0600; the folder is created with 0700."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    handle, temp = tempfile.mkstemp(prefix='.rclone-', suffix='.conf', dir=path.parent)
    try:
        os.fchmod(handle, 0o600)
        with os.fdopen(handle, 'w', encoding='utf-8') as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
        os.chmod(path, 0o600)
    except BaseException:
        if os.path.exists(temp):
            os.unlink(temp)
        raise


def reconnect(rclone, rclone_conf, remote):
    """Runs rclone's browser sign-in in the person's terminal. Its stdout goes to our stderr,
    so the JSON on stdout stays clean. Returns the exit status (None if rclone cannot start)."""
    try:
        return subprocess.run([rclone, '--config', str(rclone_conf), 'config', 'reconnect', remote + ':'],
                              stdout=sys.stderr).returncode
    except OSError:
        return None


def _worker_config(path):
    try:
        return onboarding.load_config(path) if Path(path).is_file() else None
    except Exception:
        return None


def read_values(source=None, client_id_ref=None, client_secret_ref=None, field_map=None, ask=None):
    """(client_id, secret). Order per value: its own reference, the item in --from, the prompt.
    `ask(label, secret)` is the prompt (secret_refs.prompt by default)."""
    ask = ask or secret_refs.prompt
    labels = dict(zip(FIELD_KEYS, FIELD_KEYS))
    labels.update(secret_refs.parse_field_map(field_map, FIELD_KEYS))
    values = {}
    refs = dict(client_id=client_id_ref, client_secret=client_secret_ref)
    for ref in refs.values():
        if ref:
            secret_refs.kind(ref)  # A malformed reference fails before anything is read.
    # env: first, and out of this process's environment once read, so that no child
    # process (op, security, rclone) inherits the variable that held the value.
    for key, ref in sorted(refs.items(), key=lambda item: not (item[1] or '').startswith('env:')):
        if ref:
            values[key] = secret_refs.resolve(ref)
            if ref.startswith('env:'):
                os.environ.pop(ref[len('env:'):], None)
    missing = [key for key in FIELD_KEYS if key not in values]
    if source and missing:
        found = secret_refs.resolve_fields(source, [labels[key] for key in missing])
        for key in missing:
            if labels[key] in found:
                values[key] = found[labels[key]]
        absent = [labels[key] for key in missing if key not in values]
        if absent:
            raise secret_refs.SecretRefError(
                f'{source} has no ' + ' or '.join(f'"{name}"' for name in absent) + ' field. Check the field '
                'names in the item, or name them with --field-map (for example client_secret="credential").')
    if 'client_id' not in values:
        values['client_id'] = ask('Desktop client ID', False)
    if 'client_secret' not in values:
        values['client_secret'] = ask('Desktop client secret', True)
    return values['client_id'], values['client_secret']


CLIENT_ID_ADVICE = {
    'empty_client_id': 'The Desktop client ID is empty.',
    'placeholder_client_id': 'The Desktop client ID is a placeholder from the guide, not the real one.',
    'invalid_client_id': 'That is not a Google client ID: it starts with the project number and ends in '
                         '.apps.googleusercontent.com. Use the Desktop client, not the iOS one.',
}
SECRET_ADVICE = {
    'empty_client_secret': 'The Desktop client secret is empty.',
    'placeholder_client_secret': 'The Desktop client secret is a placeholder, not the real one.',
    'invalid_client_secret': 'The Desktop client secret has characters a Google client secret never has '
                             '(spaces, quotes or line breaks) or the wrong length. Copy it again from the item.',
}


def drive_setup(prog, config_path=None, source=None, client_id_ref=None, client_secret_ref=None,
                field_map=None, remote=None, scope='drive.file', rclone_config=None, force=False,
                login=True, ask=None, sign_in=None):
    """Writes the rclone remote, runs the browser sign-in and checks the result.

    `sign_in(rclone, rclone_conf, remote)` is the sign-in step (`reconnect` by default);
    with `login=False` it is skipped and the result says how to do it."""
    config_path = Path(os.path.expanduser(config_path or onboarding.DEFAULT_CONFIG))
    worker = _worker_config(config_path) or {}
    remote = remote or worker.get('remote') or onboarding.DEFAULT_REMOTE
    retry = lambda *parts: _command(prog, config_path, *parts)  # noqa: E731
    if not onboarding.REMOTE_NAME.fullmatch(remote) or remote.strip() != remote:
        return _error('invalid_remote', 'Use a simple rclone remote name, such as captura.')
    if scope not in SCOPES:
        return _error('invalid_scope', retry('--scope', 'drive.file'),
                      'The worker needs drive.file, or drive.readonly when probe cannot see the phone\'s folder.')
    conf = Path(os.path.expanduser(rclone_config or worker.get('rclone_config') or onboarding.default_rclone_config()))
    rclone = onboarding._executable(worker.get('rclone') or 'rclone') or shutil.which('rclone')
    if login and not rclone:
        return _error('rclone_not_found', 'brew install rclone', 'rclone is needed for the Google sign-in.')
    text = ''
    if conf.exists():
        text = conf.read_text(encoding='utf-8', errors='replace')
        if text.lstrip().startswith('# Encrypted rclone configuration') or 'RCLONE_ENCRYPT_V0:' in text:
            return _error('rclone_config_encrypted',
                          'Keep the Captura remote in an unencrypted rclone config file, protected by your Mac '
                          'login ("rclone config encryption remove" decrypts the current one).')
        if any(name == remote for name, _, _ in sections(text)[1]) and not force:
            return _error('remote_exists', onboarding.command(prog, 'doctor', '--config', config_path),
                          f'rclone already has a remote named "{remote}" in {onboarding._home_relative(conf)}, so '
                          'nothing was changed. Doctor shows whether it works. To replace it (this also drops its '
                          'Google authorization), run drive-setup again with --force.',
                          remote=remote, rclone_config=onboarding._home_relative(conf))
    try:
        client_id, secret = read_values(source, client_id_ref, client_secret_ref, field_map, ask)
    except secret_refs.SecretRefError as error:
        return _error('secret_unavailable', str(error))
    client_id, problem = check_client_id(client_id)
    if problem:
        return _error(problem, CLIENT_ID_ADVICE[problem] + ' Check the value in the item, or ask the admin.')
    secret, problem = check_secret(secret)
    if problem:
        return _error(problem, SECRET_ADVICE[problem])
    write_private(conf, replace_section(text, remote, render_section(remote, client_id, secret, scope)))
    facts = dict(remote=remote, rclone_config=onboarding._home_relative(conf), type='drive', scope=scope,
                 client_id=client_id)
    login_command = _rclone_command(str(conf), remote)
    if not login:
        return dict(state='remote_written', **facts, authorized=False, next_step=login_command,
                    note='Sign in with the Google account the phone links in the browser that opens.')
    status = (sign_in or reconnect)(rclone, conf, remote)
    if status != 0:
        return dict(state='error', error='rclone_sign_in_failed', **facts, authorized=False,
                    next_step=login_command,
                    note='The remote is saved but rclone did not finish the Google sign-in. Run this to try '
                         'again, and sign in with the account the phone links.')
    return verify(prog, config_path, conf, remote, scope, client_id, facts, worker)


def verify(prog, config_path, conf, remote, scope, client_id, facts, worker):
    """Reads back only type, scope, client ID and whether a token exists."""
    parser = configparser.RawConfigParser(strict=False, interpolation=None)
    try:
        parser.read_string(Path(conf).read_text(encoding='utf-8', errors='replace'))
    except (OSError, configparser.Error):
        return dict(state='error', error='rclone_config_unreadable', **facts,
                    next_step=_rclone_command(str(conf), remote))
    if not parser.has_section(remote):
        return dict(state='error', error='remote_missing_after_sign_in', **facts, next_step=retry_text())
    section = parser[remote]
    problems = []
    if section.get('type', '') != 'drive':
        problems.append('type')
    if section.get('scope', '').strip() != scope:
        problems.append('scope')
    if section.get('client_id', '').strip() != client_id:
        problems.append('client_id')
    authorized = bool(section.get('token', '').strip())
    if problems:
        return dict(state='error', error='remote_changed', **facts, authorized=authorized,
                    note='rclone changed ' + ', '.join(problems) + ' of the remote during sign-in.',
                    next_step=retry_text())
    if not authorized:
        return dict(state='error', error='not_authorized', **facts, authorized=False,
                    next_step=_rclone_command(str(conf), remote),
                    note='rclone saved no Google authorization. Run this and sign in with the account the phone '
                         'links.')
    result = dict(state='drive_remote_ready', **facts, authorized=True)
    if worker:
        result['next_step'] = onboarding.command(prog, 'doctor', '--config', config_path)
        result['note'] = ('Then probe, once the phone has uploaded a recording (docs/worker.md steps 5 and 6).'
                          + ('' if worker.get('remote', onboarding.DEFAULT_REMOTE) == remote else
                             f' The worker config uses the remote "{worker.get("remote")}": switch with set '
                             f'--remote {remote}.'))
    else:
        parts = ['init', '--account', onboarding.ACCOUNT_PLACEHOLDER]
        if remote != onboarding.DEFAULT_REMOTE:
            parts += ['--remote', remote]
        result['next_step'] = onboarding.command(prog, *parts)
        result['note'] = ('Next create the worker settings with the Google account the phone links (docs/worker.md '
                          'step 4), then run doctor and probe.')
    return result


def retry_text():
    return 'Run drive-setup again with --force (docs/worker.md step 3).'
