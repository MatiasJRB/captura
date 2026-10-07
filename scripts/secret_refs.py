"""Read setup values from a password manager, the environment or a hidden prompt.

Python 3 standard library only. Used by `ios/scripts/configure.py --from` and
`bin/capture drive-setup`. A reference points at a value; it is not the value:

    op://Vault/Item/field      1Password CLI: `op read`
    op://Vault/Item            1Password item root: several named fields at once
    keychain://service/account macOS Keychain: `security find-generic-password -w`
    keychain://service         Keychain item root: one account per field name
    env:NAME                   an environment variable

With no reference, `prompt()` asks in the terminal; secrets are read without echo.

Rules this module keeps: child processes get argument lists (never a shell) and never a
secret in their arguments or environment; values come back only through return values;
no error message, exception or log line ever contains a value, only the reference.
"""
import getpass
import json
import os
import shutil
import subprocess
import sys

TIMEOUT = 120  # 1Password may wait for a Touch ID or app approval.


class SecretRefError(Exception):
    """A reference that cannot be read. The message says what to do; it never holds a value."""


def describe(ref):
    """The reference as it may be shown: it names where a value lives, not the value."""
    return ref


def kind(ref):
    """'op', 'op_item', 'keychain', 'keychain_item' or 'env'. Raises SecretRefError."""
    ref = (ref or '').strip()
    if ref.startswith('op://'):
        parts = ref[len('op://'):].split('/')
        if len(parts) == 2 and all(parts):
            return 'op_item'
        if len(parts) >= 3 and all(parts[:3]):
            return 'op'
        raise SecretRefError(f'"{ref}" is not a 1Password reference. Use op://Vault/Item/field for one value, '
                             'or op://Vault/Item for an item with several fields.')
    if ref.startswith('keychain://'):
        rest = ref[len('keychain://'):]
        if not rest or rest.startswith('/'):
            raise SecretRefError(f'"{ref}" is not a Keychain reference. Use keychain://service/account, or '
                                 'keychain://service for one account per field.')
        return 'keychain' if '/' in rest.strip('/') else 'keychain_item'
    if ref.startswith('env:'):
        if not ref[len('env:'):]:
            raise SecretRefError('"env:" needs a variable name, for example env:CAPTURA_CLIENT_ID.')
        return 'env'
    raise SecretRefError(f'"{ref}" is not a reference this script reads. Use op://Vault/Item/field, '
                         'keychain://service/account or env:NAME.')


def _run(command):
    """Runs a password manager CLI with captured output; (returncode, stdout, stderr).

    stdin is closed: `op item get` would read item names from a pipe."""
    try:
        result = subprocess.run(command, capture_output=True, stdin=subprocess.DEVNULL, timeout=TIMEOUT)
    except FileNotFoundError:
        return None
    except subprocess.TimeoutExpired:
        return 'timeout'
    return result.returncode, result.stdout.decode('utf-8', 'replace'), result.stderr.decode('utf-8', 'replace')


def _strip_newline(value):
    return value[:-1] if value.endswith('\n') else value


# --- 1Password ---------------------------------------------------------------------

OP_MISSING = ('The 1Password CLI ("op") is not installed. Install it (developer.1password.com/docs/cli), '
              'turn on 1Password > Settings > Developer > Integrate with 1Password CLI, then run this again. '
              'Or leave the reference out and type the value at the hidden prompt.')
OP_SIGNED_OUT = ('The 1Password CLI is not signed in. Open and unlock the 1Password app, turn on Settings > '
                 'Developer > Integrate with 1Password CLI (or run "op signin" in this Terminal), then run this '
                 'again.')


def _op_failure(ref, result, item=None, vault=None):
    if result is None:
        return SecretRefError(OP_MISSING)
    if result == 'timeout':
        return SecretRefError('1Password did not answer in time. Approve the request in the 1Password app, '
                              'then run this again.')
    _, _, err = result
    text = err.lower()
    # Most specific first: "isn't an item in the X vault" also mentions a vault.
    if "isn't a vault" in text or 'no vault' in text or 'vault not found' in text:
        return SecretRefError(f'1Password has no vault "{vault}" that you can see ({describe(ref)}). Check the '
                              'vault name with the admin who shared the item.')
    if "isn't an item" in text or 'no item' in text or 'item not found' in text:
        return SecretRefError(f'1Password has no item "{item}" that you can see ({describe(ref)}). Check that '
                              'the admin shared it with you and that the name matches.')
    if "isn't a field" in text or 'no field' in text or 'field not found' in text or 'does not have a field' in text:
        return SecretRefError(f'The 1Password item has no such field ({describe(ref)}). Check the field '
                              'name in the item.')
    if any(phrase in text for phrase in (
            'not signed in', 'not currently signed in', 'no accounts configured', 'sign in', 'signin',
            'authorization prompt dismissed', 'desktop app', 'session expired', 'unauthorized', 'locked')):
        return SecretRefError(OP_SIGNED_OUT)
    return SecretRefError(f'1Password could not read {describe(ref)} (op exited with status {result[0]}). Run '
                          '"op whoami" to check the CLI, then run this again.')


def _op_parts(ref):
    parts = ref[len('op://'):].split('/')
    return parts[0], parts[1]


def read_op(ref):
    """One value: `op read op://Vault/Item/field`."""
    vault, item = _op_parts(ref)
    result = _run([shutil.which('op') or 'op', 'read', '--no-newline', ref])
    if result is None or result == 'timeout' or result[0] != 0:
        raise _op_failure(ref, result, item, vault)
    return _strip_newline(result[1])


def read_op_item(ref, labels):
    """{label: value} for the fields named in `labels` of `op://Vault/Item`; missing ones are
    left out. The item JSON stays in memory: only the requested fields are kept."""
    vault, item = _op_parts(ref)
    result = _run([shutil.which('op') or 'op', 'item', 'get', item, '--vault', vault, '--format', 'json',
                   '--reveal'])
    if result is None or result == 'timeout' or result[0] != 0:
        raise _op_failure(ref, result, item, vault)
    try:
        data = json.loads(result[1])
    except ValueError:
        raise SecretRefError(f'1Password returned something that is not an item for {describe(ref)}. Run '
                             '"op --version"; this needs 1Password CLI 2.') from None
    fields = data.get('fields') if isinstance(data, dict) else data
    if not isinstance(fields, list):
        raise SecretRefError(f'1Password returned an item without fields for {describe(ref)}.')
    wanted = {label.lower(): label for label in labels}
    found = {}
    for field in fields:
        if not isinstance(field, dict):
            continue
        for key in (field.get('label'), field.get('id')):
            label = wanted.get(str(key or '').lower())
            if label and label not in found and isinstance(field.get('value'), str):
                found[label] = field['value']
    del data, fields
    return found


# --- macOS Keychain ----------------------------------------------------------------

def _keychain_parts(ref):
    rest = ref[len('keychain://'):].strip('/')
    service, _, account = rest.rpartition('/')
    return (service, account) if service else (rest, '')


def read_keychain(service, account, ref=None):
    """`security find-generic-password -s SERVICE -a ACCOUNT -w`; None when there is no such item."""
    ref = ref or f'keychain://{service}/{account}'
    result = _run([shutil.which('security') or '/usr/bin/security', 'find-generic-password',
                   '-s', service, '-a', account, '-w'])
    if result is None:
        raise SecretRefError('The macOS "security" tool is not available, so the Keychain cannot be read. '
                             'Use another reference or the hidden prompt.')
    if result == 'timeout':
        raise SecretRefError(f'The Keychain did not answer in time for {describe(ref)}. Allow the access '
                             'prompt, then run this again.')
    code, out, err = result
    if code == 44 or 'could not be found' in err.lower():
        return None
    if code != 0:
        raise SecretRefError(f'The Keychain refused to read {describe(ref)} (status {code}). If macOS asked '
                             'for permission, click Allow, then run this again.')
    return _strip_newline(out)


def keychain_command_hint(service, account):
    """How a person stores a value themselves; -w at the end makes `security` prompt for it."""
    return f'security add-generic-password -s "{service}" -a {account} -w'


# --- Public API ----------------------------------------------------------------------

def resolve(ref, environ=None):
    """The value one reference points at. Raises SecretRefError, never with the value."""
    ref = (ref or '').strip()
    which = kind(ref)
    if which == 'op':
        value = read_op(ref)
    elif which == 'keychain':
        service, account = _keychain_parts(ref)
        value = read_keychain(service, account, ref)
        if value is None:
            raise SecretRefError(f'The Keychain has no item {describe(ref)}. Store it first with: '
                                 f'{keychain_command_hint(service, account)}')
    elif which == 'env':
        name = ref[len('env:'):]
        value = (os.environ if environ is None else environ).get(name)
        if value is None:
            raise SecretRefError(f'The environment variable {name} is not set ({describe(ref)}).')
    else:
        raise SecretRefError(f'"{ref}" points at a whole item. Name one field: {ref}/FIELD.')
    if not value.strip():
        raise SecretRefError(f'{describe(ref)} is empty.')
    return value


def resolve_fields(source, labels):
    """{label: value} read from an item root (`op://Vault/Item` or `keychain://service`).

    Fields that do not exist are left out; the caller decides which ones are required."""
    source = (source or '').strip()
    which = kind(source)
    if which == 'op_item':
        found = read_op_item(source, labels)
    elif which == 'keychain_item':
        service, _ = _keychain_parts(source)
        found = {}
        for label in labels:
            value = read_keychain(service, label, f'keychain://{service}/{label}')
            if value is not None:
                found[label] = value
    else:
        raise SecretRefError(f'--from needs an item, not a single value: op://Vault/Item or keychain://service '
                             f'(got "{source}").')
    return {label: value for label, value in found.items() if value.strip()}


def parse_field_map(entries, allowed):
    """`["client_id=Desktop client ID", ...]` -> {key: label}. Keys must be in `allowed`."""
    mapping = {}
    for entry in entries or []:
        for part in entry.split(','):
            key, sep, label = part.partition('=')
            key, label = key.strip(), label.strip().strip('"\'')
            if not sep or not label:
                raise SecretRefError(f'--field-map takes KEY=FIELD-NAME, for example {allowed[0]}="{allowed[0]}" '
                                     f'(got "{part.strip()}").')
            if key not in allowed:
                raise SecretRefError(f'--field-map knows {", ".join(allowed)}, not "{key}".')
            mapping[key] = label
    return mapping


def prompt(label, secret, stdin=None):
    """Asks in the terminal. Secrets use getpass (no echo). Raises SecretRefError without one."""
    stdin = stdin or sys.stdin
    if not (stdin and stdin.isatty()):
        raise SecretRefError(f'No terminal to ask for the {label}. Run this in Terminal, or give a reference '
                             '(op://..., keychain://..., env:NAME).')
    try:
        if secret:
            value = getpass.getpass(f'{label} (hidden, paste and press Return): ', stream=sys.stderr)
        else:
            sys.stderr.write(f'{label}: ')
            sys.stderr.flush()
            value = stdin.readline()
    except (EOFError, KeyboardInterrupt):
        raise SecretRefError(f'No {label} was entered.') from None
    value = value.strip()
    if not value:
        raise SecretRefError(f'No {label} was entered.')
    if secret:
        sys.stderr.write(f'Got {len(value)} characters.\n')
    return value
