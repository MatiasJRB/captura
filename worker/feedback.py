"""Opt-in metadata feedback to the phone's pinned private Drive inbox.

The importer remains GET-only. This writer can replace only its own marked JSON;
it never edits recordings, folders, permissions or transcript Docs.
"""
import json
from pathlib import Path
import re
import sqlite3
import time
import urllib.error
import urllib.parse
import urllib.request

import publish as docs
import worker
from worker import SafeError, identifier

FIELDS = 'id,mimeType,parents,properties,shared,ownedByMe,trashed'
MAX_BYTES = 262144
MARKER = 'personalCaptureFeedback'


def allowed(method, url):
    if method != 'PATCH':
        return docs.allowed(method, url) and (method == 'GET' or
                (method == 'POST' and urllib.parse.urlsplit(url).path == '/upload/drive/v3/files'))
    try:
        p = urllib.parse.urlsplit(url)
        q = urllib.parse.parse_qs(p.query, strict_parsing=True)
        return (p.scheme == 'https' and p.netloc == 'www.googleapis.com' and not p.fragment
                and re.fullmatch(r'/upload/drive/v3/files/[A-Za-z0-9_-]{1,200}', p.path) is not None
                and q.get('uploadType') == ['media'] and set(q) <= {'uploadType', 'fields'}
                and all(len(v) == 1 for v in q.values()))
    except ValueError:
        return False


def verify_report(meta, folder, device):
    identifier(meta.get('id'))
    if (meta.get('mimeType') != 'application/json' or meta.get('shared') is not False
            or meta.get('ownedByMe') is not True or meta.get('trashed') is not False
            or meta.get('parents') != [folder]
            or meta.get('properties', {}).get(MARKER) != '1'
            or meta.get('properties', {}).get('sourceFolder') != folder
            or meta.get('properties', {}).get('device') != device):
        raise SafeError('feedback_report_not_private_or_matching')


class Writer(docs.Writer):
    def call(self, method, path, params=None, body=None, content_type=None):
        url = 'https://www.googleapis.com' + path + ('?' + urllib.parse.urlencode(params) if params else '')
        if not allowed(method, url):
            raise SafeError('feedback_request_not_allowed')
        headers = dict(Authorization='Bearer ' + self.token)
        if self.quota_project: headers['X-Goog-User-Project'] = self.quota_project
        if content_type: headers['Content-Type'] = content_type
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=30) as response:
                raw = response.read(MAX_BYTES + 1)
        except urllib.error.HTTPError as error:
            raise SafeError('feedback_http_' + str(int(error.code))) from None
        except SafeError:
            raise
        except Exception:
            raise SafeError('feedback_connection_failed') from None
        if len(raw) > MAX_BYTES: raise SafeError('feedback_response_too_large')
        try: return json.loads(raw)
        except ValueError: raise SafeError('feedback_invalid_response') from None

    def find_reports(self, folder):
        return self.search("trashed=false and '" + identifier(folder)
                           + "' in parents and properties has { key='" + MARKER + "' and value='1' }", FIELDS)

    def create_report(self, folder, device, payload):
        current = self.folder_by_id(folder)
        worker.verify_folder(current, folder)
        if current['properties']['device'] != device: raise SafeError('feedback_device_changed')
        meta = dict(name='Captura transcription status.json', mimeType='application/json',
                    parents=[folder], properties={MARKER:'1', 'sourceFolder':folder, 'device':device})
        body, boundary = docs.multipart(meta, json.dumps(payload, separators=(',', ':')))
        body = body.replace(b'Content-Type: text/plain;', b'Content-Type: application/json;')
        result = self.call('POST', '/upload/drive/v3/files', dict(uploadType='multipart', fields=FIELDS),
                           body, 'multipart/related; boundary=' + boundary)
        verify_report(result, folder, device)
        return result

    def update_report(self, meta, payload):
        folder, device = payload['folder_id'], payload['device_id']
        current_folder = self.folder_by_id(folder)
        worker.verify_folder(current_folder, folder)
        if current_folder['properties']['device'] != device: raise SafeError('feedback_device_changed')
        fid = identifier(meta.get('id'))
        fresh = self.call('GET', '/drive/v3/files/' + fid, dict(fields=FIELDS))
        verify_report(fresh, folder, device)
        return self.call('PATCH', '/upload/drive/v3/files/' + fid, dict(uploadType='media', fields='id'),
                         json.dumps(payload, separators=(',', ':')).encode(), 'application/json; charset=UTF-8')


def snapshot(config, device, now=None):
    root = Path(config['root']).resolve()
    folder = identifier(config['folder_id'])
    result = dict(schema_version=1, folder_id=folder, device_id=device,
                  generated_at=int((time.time() if now is None else now) * 1000), available=False, records=[])
    database = root/'receipts.sqlite'
    if database.is_symlink() or not database.is_file(): return result
    with sqlite3.connect(database.as_uri()+'?mode=ro', uri=True) as db:
        db.execute('PRAGMA query_only=ON')
        rows = db.execute('SELECT id,sha,state FROM receipts ORDER BY at DESC LIMIT 500').fetchall()
        tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        failures = {r[0] for r in db.execute('SELECT id FROM failures WHERE attempts>0')} if 'failures' in tables else set()
    for fid, sha, state in rows:
        if not isinstance(fid,str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,200}',fid): continue
        if not isinstance(sha,str) or not re.fullmatch(r'[a-f0-9]{64}',sha): continue
        item = root/fid; source = item/'source.json'
        try:
            if item.is_symlink() or source.is_symlink() or source.stat().st_size > 65536: continue
            meta = json.loads(source.read_text())
            if meta.get('sha256') != sha or folder not in meta.get('drive',{}).get('parents',[]): continue
            if state == 'review':
                if not all((item/n).is_file() and not (item/n).is_symlink() for n in ['transcript.txt','transcript.json']): continue
                value = 'transcribed'
            elif state == 'downloaded': value = 'error' if fid in failures else 'downloaded'
            else: continue
            result['records'].append(dict(id=fid, sha256=sha, state=value))
        except (OSError, ValueError, TypeError, AttributeError): continue
    result['available'] = True
    if len(json.dumps(result).encode()) > MAX_BYTES: raise SafeError('feedback_report_too_large')
    return result


def publish(config, dry_run=False, writer=None):
    if dry_run:
        return dict(state='preview', network=False, sends='IDs, hashes and processing states only',
                    enabled=config.get('feedback') is True)
    if config.get('feedback') is not True: return dict(state='disabled')
    folder = identifier(config.get('folder_id'))
    with worker.lock(Path(config['root'])):
        writer = writer or Writer(config)
        account = writer.account()
        expected = config.get('expected_account')
        if (not isinstance(account, str) or not isinstance(expected, str) or not expected
                or account.casefold() != expected.casefold()):
            raise SafeError('feedback_account_mismatch')
        meta = writer.folder_by_id(folder); worker.verify_folder(meta, folder)
        device = meta['properties']['device']
        report = snapshot(config, device)
        if not report['available']: raise SafeError('feedback_receipts_unavailable')
        files = writer.find_reports(folder)
        if len(files) > 1: raise SafeError('feedback_duplicate_reports')
        if files:
            verify_report(files[0], folder, device)
            writer.update_report(files[0], report)
        else:
            writer.create_report(folder, device, report)
        return dict(state='published', records=len(report['records']))


def after_run(config):
    if config.get('feedback') is not True: return None
    try: return publish(config)
    except (SafeError, OSError, sqlite3.Error) as error:
        return dict(state='error', error=str(error) if isinstance(error,SafeError) else 'feedback_local_error')
