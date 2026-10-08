"""Opt-in writer: one Google Doc per finished transcript, in one private Drive folder.

Separate from the importer (worker.py), which stays GET-only. This module may write, but
only through its own allowlist: https://www.googleapis.com, no redirects, and exactly
these requests:

- GET  /drive/v3/about                   the signed-in account
- GET  /drive/v3/files                   find its folder, or a Doc, by property
- GET  /drive/v3/files/ID                re-check the remembered folder
- POST /drive/v3/files                   create its folder (metadata only)
- POST /upload/drive/v3/files            multipart upload of one Doc (uploadType=multipart)

It never updates, moves, shares or deletes anything in Drive, never uploads audio, and
never prints or logs the token. Transcript text is untrusted data: it is sent as
text/plain and only converted to a Google Doc, never interpreted as markup.
`record.json` on the Mac stays the source of truth; the Doc is a convenience copy.
"""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request

import reader
import worker
from worker import SafeError, identifier

HOST = 'www.googleapis.com'
FOLDER_NAME = 'Captura · transcripciones'
FOLDER_MIME = 'application/vnd.google-apps.folder'
DOC_MIME = 'application/vnd.google-apps.document'
FOLDER_PROPERTY = 'personalCaptureTranscripts'
FOLDER_FIELDS = 'id,name,mimeType,properties,shared,ownedByMe,trashed'
DOC_FIELDS = 'id,name,mimeType,parents,properties'
STATE_FILE = 'published.json'
MAX_RESPONSE = 1024 * 1024
MAX_ERRORS = 3
DISCLAIMER = ('Transcripción automática de Captura — borrador a revisar. '
              'Puede tener errores y no identifica quién habla.')
NO_SPEECH = ('No se detectó voz en la salida del modelo. Revisá el audio original: '
             'no es una garantía de silencio.')
# (method, exact path pattern, allowed query keys). Nothing else leaves this module.
ROUTES = (
    ('GET', re.compile(r'/drive/v3/about'), frozenset({'fields'})),
    ('GET', re.compile(r'/drive/v3/files'), frozenset({'q', 'fields', 'pageSize', 'pageToken', 'spaces'})),
    ('GET', re.compile(r'/drive/v3/files/[A-Za-z0-9_-]{1,200}'), frozenset({'fields'})),
    ('POST', re.compile(r'/drive/v3/files'), frozenset({'fields'})),
    ('POST', re.compile(r'/upload/drive/v3/files'), frozenset({'uploadType', 'fields'})),
)
CONTROL = re.compile(r'[\x00-\x08\x0b-\x1f\x7f-\x9f  ]')


def allowed(method, url):
    """True only for the requests listed in ROUTES, on https://www.googleapis.com."""
    try:
        parts = urllib.parse.urlsplit(url)
        params = urllib.parse.parse_qs(parts.query, keep_blank_values=True, strict_parsing=bool(parts.query))
    except ValueError:
        return False
    if (parts.scheme != 'https' or parts.netloc != HOST or parts.fragment
            or any(len(values) != 1 for values in params.values())):
        return False
    for verb, path, keys in ROUTES:
        if method == verb and path.fullmatch(parts.path) and set(params) <= keys:
            if parts.path.startswith('/upload/'):
                return params.get('uploadType') == ['multipart']
            return True
    return False


def clean(text, limit=None):
    """Plain text without control characters (newlines and tabs kept)."""
    text = CONTROL.sub(' ', str(text))
    return text[:limit] if limit else text


def one_line(text, limit=120):
    return ' '.join(clean(text).split())[:limit]


class Writer:
    """Drive calls for publishing. `opener` and `token` are injectable for tests."""

    def __init__(self, config, opener=None, token=None):
        self.quota_project = worker.quota_project(config)
        self.token = token if token is not None else worker.drive_token(config, self.quota_project)
        self.opener = opener or urllib.request.build_opener(worker.NoRedirect())

    def call(self, method, path, params=None, body=None, content_type=None):
        url = 'https://' + HOST + path + ('?' + urllib.parse.urlencode(params) if params else '')
        if not allowed(method, url):
            raise SafeError('publish_request_not_allowed')
        headers = {'Authorization': 'Bearer ' + self.token}
        if self.quota_project:
            headers['X-Goog-User-Project'] = self.quota_project
        if content_type:
            headers['Content-Type'] = content_type
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=60) as response:
                raw = response.read(MAX_RESPONSE + 1)
        except urllib.error.HTTPError as error:
            try:
                details = error.read(65536).decode('utf-8', errors='replace')
            except Exception:
                details = ''
            if error.code == 429 or (error.code == 403 and any(
                    s in details for s in ('rateLimitExceeded', 'RATE_LIMIT_EXCEEDED', 'QUOTA_EXCEEDED',
                                           'userRateLimitExceeded'))):
                raise SafeError('publish_rate_limit_retry_later') from None
            if error.code == 403 and any(s in details for s in ('insufficientPermissions',
                                                                 'ACCESS_TOKEN_SCOPE_INSUFFICIENT')):
                raise SafeError('publish_needs_drive_file_scope') from None
            raise SafeError('publish_http_' + str(int(error.code))) from None
        except SafeError:
            raise
        except Exception:
            raise SafeError('publish_connection_failed') from None
        if len(raw) > MAX_RESPONSE:
            raise SafeError('publish_response_too_large')
        try:
            return json.loads(raw)
        except ValueError:
            raise SafeError('publish_invalid_response') from None

    def account(self):
        try:
            return self.call('GET', '/drive/v3/about', {'fields': 'user(emailAddress)'})['user']['emailAddress']
        except (KeyError, TypeError):
            raise SafeError('publish_invalid_response') from None

    def search(self, query, fields):
        files, token = [], None
        for _ in range(20):
            params = dict(q=query, fields='nextPageToken,files(' + fields + ')', pageSize=100, spaces='drive')
            if token:
                params['pageToken'] = token
            result = self.call('GET', '/drive/v3/files', params)
            files += result.get('files', [])
            token = result.get('nextPageToken')
            if not token:
                return files
        raise SafeError('publish_page_limit')

    def folder_by_id(self, folder_id):
        return self.call('GET', '/drive/v3/files/' + identifier(folder_id), {'fields': FOLDER_FIELDS})

    def find_folders(self):
        return self.search("trashed=false and mimeType='" + FOLDER_MIME + "' and properties has { key='"
                           + FOLDER_PROPERTY + "' and value='1' }", FOLDER_FIELDS)

    def create_folder(self):
        metadata = dict(name=FOLDER_NAME, mimeType=FOLDER_MIME, properties={FOLDER_PROPERTY: '1'})
        return self.call('POST', '/drive/v3/files', {'fields': FOLDER_FIELDS},
                         json.dumps(metadata).encode(), 'application/json; charset=UTF-8')

    def find_doc(self, folder_id, record_id):
        return self.search("trashed=false and '" + identifier(folder_id) + "' in parents and properties has "
                           "{ key='captureRecordId' and value='" + identifier(record_id) + "' }", DOC_FIELDS)

    def create_doc(self, folder_id, title, text, properties):
        body, boundary = multipart(doc_metadata(folder_id, title, properties), text)
        result = self.call('POST', '/upload/drive/v3/files', {'uploadType': 'multipart', 'fields': DOC_FIELDS},
                           body, 'multipart/related; boundary=' + boundary)
        identifier(result.get('id'))
        if result.get('mimeType') != DOC_MIME:
            raise SafeError('publish_not_converted_to_doc')
        return result


def doc_metadata(folder_id, title, properties):
    return dict(name=title, mimeType=DOC_MIME, parents=[identifier(folder_id)], properties=properties)


def multipart(metadata, text):
    """(body, boundary): JSON metadata, then the text as text/plain, for Drive's multipart upload."""
    data = text.encode('utf-8')
    meta = json.dumps(metadata, ensure_ascii=False).encode('utf-8')
    while True:
        boundary = 'captura-' + secrets.token_hex(16)
        if boundary.encode() not in data and boundary.encode() not in meta:
            break
    mark = b'--' + boundary.encode()
    body = (mark + b'\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n' + meta + b'\r\n'
            + mark + b'\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n' + data + b'\r\n' + mark + b'--\r\n')
    return body, boundary


def verify_folder(meta):
    """The transcripts folder must be a folder of ours, owned by the account and not shared."""
    if not isinstance(meta, dict):
        raise SafeError('publish_invalid_response')
    identifier(meta.get('id'))
    if meta.get('trashed') is not False:
        raise SafeError('transcripts_folder_trashed')
    if meta.get('ownedByMe') is not True:
        raise SafeError('transcripts_folder_not_owned')
    if meta.get('shared') is not False:
        raise SafeError('transcripts_folder_shared')
    if (meta.get('mimeType') != FOLDER_MIME
            or (meta.get('properties') or {}).get(FOLDER_PROPERTY) != '1'):
        raise SafeError('transcripts_folder_invalid')
    return meta


def local_time(value, tz=None):
    """An ISO timestamp as 'YYYY-MM-DD HH:MM' in local time (or `tz`)."""
    try:
        moment = datetime.fromisoformat(str(value).replace('Z', '+00:00'))
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.astimezone(tz).strftime('%Y-%m-%d %H:%M')


def audio_name(root, record_id):
    """The original file name the phone gave, from source.json; None if unknown."""
    path = Path(root) / record_id / 'source.json'
    try:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_RESPONSE:
            return None
        name = json.loads(path.read_text()).get('drive', {}).get('name')
    except (OSError, ValueError, AttributeError):
        return None
    if not isinstance(name, str):
        return None
    return one_line(name) or None


def title(record, name=None, tz=None):
    when = local_time(record.get('recorded_at') or record.get('processed_at'), tz) or 'sin fecha'
    return when + ' · ' + (one_line(name or '') or record['id'])


def body(record, name=None, tz=None):
    """The Doc text: Spanish header, then '[mm:ss] text' per segment. Plain text only."""
    when = local_time(record.get('recorded_at') or record.get('processed_at'), tz) or 'sin fecha'
    engine = record.get('engine') or {}
    model = one_line(engine.get('model') or 'desconocido')
    if engine.get('name'):
        model += ' (' + one_line(engine['name']) + (', con detección de voz' if engine.get('vad') else '') + ')'
    lines = [DISCLAIMER, '',
             'Audio: ' + (one_line(name or '') or 'sin nombre'),
             'ID del registro: ' + record['id'],
             'Fecha: ' + when + (' (grabación)' if record.get('recorded_at') else ' (transcripción)'),
             'Idioma: ' + one_line(record.get('language') or 'desconocido', 16),
             'Modelo: ' + model,
             '']
    segments = record['transcript']['segments']
    for segment in segments:
        lines.append('[' + reader.clock(segment['start_ms']) + '] ' + ' '.join(clean(segment['text']).split()))
    if not segments:
        lines.append(NO_SPEECH)
    return '\n'.join(lines) + '\n'


def doc_url(doc_id):
    return 'https://docs.google.com/document/d/' + identifier(doc_id) + '/edit'


def load_state(root):
    path = Path(root) / STATE_FILE
    if not path.exists():
        return dict(schema_version=1, folder_id=None, account=None, records={})
    try:
        if path.is_symlink() or path.stat().st_size > 8 * MAX_RESPONSE:
            raise ValueError()
        state = json.loads(path.read_text())
        if state.get('schema_version') != 1 or not isinstance(state.get('records'), dict):
            raise ValueError()
        if state.get('folder_id') is not None:
            identifier(state['folder_id'])
    except (OSError, ValueError, AttributeError, SafeError):
        raise SafeError('invalid_publish_state') from None
    return state


def save_state(root, state):
    worker.write_json(Path(root) / STATE_FILE, state)


def folder_known(config):
    """The remembered folder ID, read locally (for doctor); None when not created yet."""
    try:
        return load_state(Path(config['root']).expanduser()).get('folder_id')
    except (SafeError, KeyError):
        return None


def resolve_folder(writer, state):
    """The remembered folder (re-checked), else the one found by property, else a new one."""
    if state.get('folder_id'):
        try:
            meta = writer.folder_by_id(state['folder_id'])
        except SafeError as error:
            if str(error) == 'publish_http_404':
                raise SafeError('transcripts_folder_missing') from None
            raise
        if meta.get('id') != state['folder_id']:
            raise SafeError('transcripts_folder_invalid')
        return verify_folder(meta)
    found = writer.find_folders()
    if len(found) > 1:
        raise SafeError('ambiguous_transcript_folders')
    if found:
        return verify_folder(found[0])
    return verify_folder(writer.create_folder())


def pending(root, state, include_empty):
    """(to publish, already published, skipped empty, invalid ids) from the local inbox only."""
    data = reader.records(root)
    todo, done, empty = [], [], []
    for record in data['records']:
        receipt = state['records'].get(record['id'])
        if receipt:
            if receipt.get('sha256') != record['original'].get('sha256'):
                todo.append(record)  # Reported as an error below, never republished silently.
            else:
                done.append(record['id'])
        elif record['state'] == 'no_speech_detected' and not include_empty:
            empty.append(record['id'])
        else:
            todo.append(record)
    return todo, done, empty, data['errors']


def publish(config, dry_run=False, include_empty=False, writer_factory=Writer, tz=None):
    """Publish every finished record not published yet. Returns a JSON-able summary."""
    root = Path(config['root']).expanduser()
    status = dict(at=datetime.now().astimezone().isoformat(timespec='seconds'), state='checking',
                  dry_run=bool(dry_run), published=0, skipped=0, skipped_empty=0, errors=[], docs=[])
    try:
        state = load_state(root)
        if state.get('account') and state['account'].lower() != config['expected_account'].lower():
            raise SafeError('publish_state_other_account')
        todo, done, empty, invalid = pending(root, state, include_empty)
        status.update(skipped=len(done) + len(empty), skipped_empty=len(empty), folder_id=state.get('folder_id'))
        for bad in invalid:
            status['errors'].append(dict(id=bad['id'], error=bad['error']))
        if dry_run:
            # Offline: lists what a real publish would send, from the local inbox and receipt.
            status.update(state='dry_run', would_publish=[
                dict(id=r['id'], title=title(r, audio_name(root, r['id']), tz)) for r in todo])
            return status
        if not todo:
            # Everything is on the local receipt: no token, no network.
            status['state'] = 'needs_review' if status['errors'] else 'nothing_to_publish'
            return status
        with worker.lock(root):
            writer = writer_factory(config)
            if writer.account().lower() != config['expected_account'].lower():
                raise SafeError('drive_account_mismatch')
            folder = resolve_folder(writer, state)
            if state.get('folder_id') != folder['id']:
                state.update(folder_id=folder['id'], account=config['expected_account'])
                save_state(root, state)
            status['folder_id'] = folder['id']
            failures = 0
            for record in todo:
                rid = record['id']
                sha = record['original'].get('sha256')
                try:
                    receipt = state['records'].get(rid)
                    if receipt and receipt.get('sha256') != sha:
                        raise SafeError('published_record_changed')
                    existing = writer.find_doc(folder['id'], rid)
                    if existing:
                        doc = existing[0]
                        identifier(doc.get('id'))
                        status['skipped'] += 1
                    else:
                        name = audio_name(root, rid)
                        properties = dict(captureRecordId=rid)
                        if sha:
                            properties['captureOriginalSha256'] = sha
                        doc = writer.create_doc(folder['id'], title(record, name, tz), body(record, name, tz),
                                                properties)
                        status['published'] += 1
                        status['docs'].append(dict(id=rid, title=doc.get('name'), url=doc_url(doc['id'])))
                    state['records'][rid] = dict(doc_id=doc['id'], sha256=sha, at=time.time())
                    save_state(root, state)
                except SafeError as error:
                    status['errors'].append(dict(id=rid, error=str(error)))
                    failures += 1
                    if str(error).startswith(('publish_rate_limit', 'publish_connection', 'publish_needs',
                                              'publish_http_401')) or failures >= MAX_ERRORS:
                        break
        status['state'] = 'needs_review' if status['errors'] else 'published'
        return status
    except Exception as error:
        status.update(state='error', errors=[dict(error=str(error) if isinstance(error, SafeError)
                                                  else 'publish_failed')])
        return status


def after_run(config, status, **options):
    """`capture run` with "publish": true: publish right after a run that reached Drive."""
    if config.get('publish') is not True or status.get('state') not in ('ready', 'needs_review'):
        return None
    return publish(config, **options)


HINTS = {
    'transcripts_folder_shared': 'The Drive folder «Captura · transcripciones» is shared. Stop sharing it in '
                                 'Google Drive (share single Docs instead), then publish again.',
    'transcripts_folder_not_owned': 'The folder «Captura · transcripciones» found in Drive belongs to another '
                                    'account. Remove it from your Drive, then publish again.',
    'transcripts_folder_trashed': 'The folder «Captura · transcripciones» is in the Drive trash. Restore it, '
                                  'or delete published.json in the inbox to publish into a new folder.',
    'transcripts_folder_missing': 'The folder «Captura · transcripciones» is gone from Drive. Delete '
                                  'published.json in the inbox to publish into a new folder.',
    'transcripts_folder_invalid': 'The remembered Drive folder is not a Captura transcripts folder. Delete '
                                  'published.json in the inbox, then publish again.',
    'ambiguous_transcript_folders': 'Drive has more than one «Captura · transcripciones» folder. Keep one '
                                    '(move the Docs, trash the others), then publish again.',
    'publish_needs_drive_file_scope': 'The rclone remote cannot create files (scope drive.readonly). Publishing '
                                      'needs scope drive.file (docs/worker.md step 3).',
    'publish_state_other_account': 'published.json in the inbox belongs to another Google account. Move it '
                                   'away to publish for this account.',
    'invalid_publish_state': 'published.json in the inbox is damaged. Move it away, then publish again; Docs '
                             'already in Drive are found by their record ID and not duplicated.',
    'publish_rate_limit_retry_later': 'Google asked to slow down. Try again in a few minutes.',
    'publish_connection_failed': 'No connection to Google Drive. Check the internet connection and try again.',
    'worker_already_running': 'Another run is still working. Wait for it to finish.',
}


def advice(result, config_path, config, prog):
    """next_step/note for a person, in the style of doctor's advice. Never changes the result."""
    import onboarding  # Local import: onboarding imports worker, not this module.
    codes = [e.get('error') for e in result.get('errors') or []]
    if result.get('state') == 'dry_run':
        count = len(result.get('would_publish') or [])
        if not count:
            return dict(note='Nothing new to publish.')
        return dict(note=f'{count} transcript(s) would be copied to «{FOLDER_NAME}» in Google Drive. Nothing '
                         'was sent.', next_step=onboarding.command(prog, 'publish', '--config', config_path))
    for code in codes:
        if code in HINTS:
            return dict(next_step=HINTS[code])
    auth = onboarding.hint(dict(state='error', errors=codes[:1]), config_path, config, prog) if codes else {}
    if auth:
        return auth
    if result.get('state') == 'nothing_to_publish':
        return dict(note='Nothing new to publish: every finished transcript is already in Google Drive.')
    if result.get('state') == 'published':
        return dict(note=f'Copied {result["published"]} transcript(s) to «{FOLDER_NAME}» in Google Drive.',
                    next_step='Open Google Drive on the phone or the web and look in that folder.')
    return {}
