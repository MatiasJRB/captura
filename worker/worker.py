#!/usr/bin/env python3
"""Read-only Drive inbox -> verified private audio -> local ASR REVIEW, never actions."""
import argparse
import configparser
import contextlib
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import time
import tempfile
import urllib.error
import urllib.parse
import urllib.request

API = 'https://www.googleapis.com/drive/v3/'
MAX_AUDIO = 64 * 1024 * 1024
FIELDS = 'id,name,mimeType,size,md5Checksum,parents,properties,shared,ownedByMe,trashed'

class SafeError(Exception):
    pass

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise SafeError('google_redirect_rejected')

def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,200}', value):
        raise SafeError('invalid_drive_id')
    return value

def verify_folder(meta, expected=None):
    identifier(meta.get('id'))
    if expected and meta['id'] != expected:
        raise SafeError('wrong_folder')
    if (meta.get('mimeType') != 'application/vnd.google-apps.folder'
            or meta.get('shared') is not False or meta.get('ownedByMe') is not True
            or meta.get('trashed') is not False
            or meta.get('properties', {}).get('personalCaptureInbox') != '1'
            or not meta.get('properties', {}).get('device')):
        raise SafeError('folder_not_private_capture')
    return meta

def verify_audio(meta, folder):
    identifier(meta.get('id'))
    props = meta.get('properties', {})
    if (meta.get('shared') is not False or meta.get('ownedByMe') is not True
            or meta.get('trashed') is not False or folder not in meta.get('parents', [])
            or meta.get('mimeType') not in ('audio/mp4', 'audio/x-m4a')
            or props.get('personalCaptureAudio') != '1'
            or not re.fullmatch(r'[0-9a-f]{64}', props.get('sha256', ''))
            or not re.fullmatch(r'[0-9a-f]{32}', meta.get('md5Checksum', ''))):
        raise SafeError('invalid_audio_metadata')
    try:
        size = int(meta.get('size', 0))
    except (ValueError, TypeError):
        raise SafeError('invalid_audio_size')
    if not 1024 < size <= MAX_AUDIO:
        raise SafeError('audio_size_out_of_bounds')
    return size

def validate_bytes(path, meta):
    md5, sha = hashlib.md5(), hashlib.sha256()
    length = 0
    with path.open('rb') as stream:
        while chunk := stream.read(65536):
            length += len(chunk)
            md5.update(chunk)
            sha.update(chunk)
    if (length != int(meta['size']) or md5.hexdigest() != meta['md5Checksum']
            or sha.hexdigest() != meta['properties']['sha256']):
        raise SafeError('download_checksum_mismatch')
    return sha.hexdigest()

class Drive:
    def __init__(self, config):
        self.quota_project = config.get('quota_project')
        if self.quota_project and not re.fullmatch(r'[a-z][a-z0-9-]{4,61}[a-z0-9]', self.quota_project):
            raise SafeError('invalid_quota_project')
        # Reuse a still-valid SDK/CLI-managed token; don't spend Drive calls refreshing each run.
        def cached():
            parser = configparser.RawConfigParser()
            parser.read(config['rclone_config'])
            if parser[config['remote']]['type'] != 'drive':
                raise SafeError('remote_not_drive')
            token = json.loads(parser[config['remote']]['token'])
            expiry = datetime.fromisoformat(token.get('expiry', '').replace('Z', '+00:00'))
            return token if expiry.timestamp() > time.time() + 60 else None
        try:
            token = cached()
            if token is None:
                # Refresh EXISTING authorization only. Never export it to Android or logs.
                command = [config['rclone'], 'about', config['remote'] + ':', '--json',
                            '--config', config['rclone_config'], '--retries', '1',
                            '--low-level-retries', '1', '--timeout', '20s', '--contimeout', '10s']
                if self.quota_project:
                    command += ['--header', 'X-Goog-User-Project: ' + self.quota_project]
                subprocess.run(command, timeout=45, check=True, capture_output=True)
                token = cached()
            if token is None:
                raise SafeError('existing_drive_authorization_expired')
            self.token = token['access_token']
        except SafeError:
            raise
        except Exception:
            raise SafeError('existing_drive_authorization_unavailable')
        self.opener = urllib.request.build_opener(NoRedirect())

    def request(self, path, params):
        # Only GET, fixed host, no arbitrary URLs, no redirects, no secret-bearing logs.
        if not re.fullmatch(r'(about|files|files/[A-Za-z0-9_-]+)', path):
            raise SafeError('invalid_api_path')
        url = API + path + '?' + urllib.parse.urlencode(params)
        headers = {'Authorization': 'Bearer ' + self.token}
        if self.quota_project:
            headers['X-Goog-User-Project'] = self.quota_project
        request = urllib.request.Request(url, headers=headers)
        try:
            return self.opener.open(request, timeout=30)
        except urllib.error.HTTPError as error:
            details = error.read(65536).decode('utf-8', errors='replace')
            if error.code == 429 or (error.code == 403 and any(s in details for s in ('rateLimitExceeded', 'RATE_LIMIT_EXCEEDED', 'QUOTA_EXCEEDED'))):
                raise SafeError('drive_rate_limit_retry_later') from None
            raise SafeError('drive_http_' + str(error.code)) from None
        except Exception:
            raise SafeError('drive_connection_failed') from None

    def get(self, path, **params):
        with self.request(path, params) as response:
            raw = response.read(1024 * 1024 + 1)
            if len(raw) > 1024 * 1024:
                raise SafeError('metadata_too_large')
            return json.loads(raw)

    def list(self, query):
        token = None
        for _ in range(100):
            params = dict(q=query, fields='nextPageToken,files(' + FIELDS + ')', pageSize=100)
            if token:
                params['pageToken'] = token
            result = self.get('files', **params)
            yield from result.get('files', [])
            token = result.get('nextPageToken')
            if not token:
                return
        raise SafeError('inbox_page_limit')

    def folder(self, configured):
        if configured:
            return verify_folder(self.get('files/' + identifier(configured), fields=FIELDS), configured)
        folders = list(self.list("trashed=false and 'me' in owners and mimeType='application/vnd.google-apps.folder' and properties has { key='personalCaptureInbox' and value='1' }"))
        if not folders:
            return None
        if len(folders) != 1:
            raise SafeError('ambiguous_capture_folders')
        return verify_folder(folders[0])

    def download(self, meta, path):
        with self.request('files/' + identifier(meta['id']), {'alt': 'media'}) as response, path.open('wb') as output:
            length = 0
            while chunk := response.read(65536):
                length += len(chunk)
                if length > int(meta['size']) or length > MAX_AUDIO:
                    raise SafeError('download_too_large')
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
        validate_bytes(path, meta)

@contextlib.contextmanager
def lock(root):
    import fcntl
    with (root / '.worker.lock').open('a') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SafeError('worker_already_running')
        yield


def write_json(path, data):
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    os.chmod(temp, 0o600)
    temp.replace(path)


def transcribe(config, source, output):
    """Local VAD-assisted ASR, atomically staged; never execute transcript text."""
    vad = Path(config.get('vad_model', '')).expanduser()
    if not config.get('vad_model') or not vad.is_file():
        raise SafeError('vad_model_required')
    language = config.get('language', 'es')
    if not re.fullmatch(r'[a-z]{2,3}|auto', language):
        raise SafeError('invalid_language')
    with tempfile.TemporaryDirectory(prefix='.asr-', dir=output) as scratch:
        scratch = Path(scratch)
        wav, prefix = scratch / 'voice.wav', scratch / 'transcript'
        subprocess.run([config['ffmpeg'], '-nostdin', '-v', 'error', '-y', '-i', str(source),
                        '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', str(wav)],
                       check=True, timeout=120, capture_output=True)
        subprocess.run([config['whisper'], '-m', config['model'], '-f', str(wav), '-l', language,
                        '-mc', '0', '--vad', '--vad-model', str(vad),
                        '-otxt', '-oj', '-osrt', '-of', str(prefix)],
                       check=True, timeout=600, capture_output=True)
        # An unsupported flag can print help and exit 0: stale output never counts.
        paths = [prefix.with_suffix(ext) for ext in ('.txt', '.json', '.srt')]
        if not all(p.is_file() for p in paths):
            raise SafeError('asr_output_missing')
        try:
            raw = json.loads(paths[1].read_text())
            entries = raw['transcription']
            if not isinstance(entries, list):
                raise ValueError()
            segments = []
            for entry in entries:
                offsets = entry['offsets']
                start, end, text = offsets['from'], offsets['to'], entry['text']
                if (type(start) is not int or type(end) is not int or start < 0
                        or end < start or not isinstance(text, str)):
                    raise ValueError()
                if text.strip():
                    segments.append(dict(start_ms=start, end_ms=end, text=text.strip()))
        except (KeyError, TypeError, ValueError):
            raise SafeError('asr_invalid_json') from None
        # Empty valid output is a reviewable result, not an endless retry of silence.
        # VAD is not a guarantee of no speech and does not identify any speaker.
        state = 'needs_review' if segments else 'no_speech_detected'
        sha = hashlib.sha256(source.read_bytes()).hexdigest()
        record = dict(schema_version=1, id=identifier(output.name), review_only=True,
                      state=state, language=language, recorded_at=None,
                      processed_at=datetime.now(timezone.utc).isoformat(),
                      original=dict(path='original.m4a', sha256=sha),
                      transcript=dict(text=' '.join(x['text'] for x in segments),
                                      segments=segments),
                      engine=dict(name='whisper.cpp', model=Path(config['model']).name,
                                  vad=True), speaker_verified=False)
        for path in paths:
            os.chmod(path, 0o600)
            path.replace(output / path.name)
        write_json(output / 'record.json', record)  # commit marker written last


def load_config(path):
    config = json.loads(Path(path).expanduser().read_text())
    for key in ('root', 'rclone_config', 'model', 'vad_model', 'rclone', 'ffmpeg', 'whisper'):
        if key in config and isinstance(config[key], str):
            config[key] = os.path.expanduser(config[key])
    for key in ('root', 'expected_account', 'remote', 'rclone_config', 'rclone'):
        if not isinstance(config.get(key), str) or not config[key].strip():
            raise SafeError('missing_config_' + key)
    return config


def run(config, probe=False, drive_factory=Drive):
    root = Path(config['root']).expanduser()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(root, 0o700)
    with lock(root):
        status = dict(at=time.time(), state='checking', downloaded=0, transcribed=0, quarantined=0, errors=[])
        try:
            drive = drive_factory(config)
            account = drive.get('about', fields='user(emailAddress)')['user']['emailAddress']
            if account.lower() != config['expected_account'].lower():
                raise SafeError('drive_account_mismatch')
            folder = drive.folder(config.get('folder_id'))
            if folder is None:
                status['state'] = 'waiting_for_phone_folder'
                return status
            status['folder_id'] = identifier(folder['id'])
            if probe:
                status['state'] = 'private_inbox_verified'
                return status
            # Even after discovery, a human installs the exact folder ID: no wildcard imports.
            if not config.get('folder_id'):
                status['state'] = 'waiting_for_exact_folder_configuration'
                return status
            with sqlite3.connect(root / 'receipts.sqlite') as database:
                database.execute('CREATE TABLE IF NOT EXISTS receipts(id TEXT PRIMARY KEY,sha TEXT NOT NULL,state TEXT NOT NULL,at REAL)')
                database.execute('CREATE TABLE IF NOT EXISTS failures(id TEXT PRIMARY KEY,code TEXT,attempts INTEGER,at REAL)')
                downloaded, transcribed = 0, 0
                for meta in drive.list("trashed=false and '" + folder['id'] + "' in parents and properties has { key='personalCaptureAudio' and value='1' }"):
                    try:
                        failed = database.execute('SELECT attempts FROM failures WHERE id=?', (meta.get('id', ''),)).fetchone()
                        if failed and failed[0] >= 3:
                            continue  # Keep evidence for human review; don't starve the rest of the inbox.
                        verify_audio(meta, folder['id'])
                        fid, sha = meta['id'], meta['properties']['sha256']
                        previous = database.execute('SELECT sha,state FROM receipts WHERE id=?', (fid,)).fetchone()
                        if previous and previous[0] != sha:
                            raise SafeError('accepted_remote_audio_changed')
                        if previous and previous[1] == 'review':
                            continue
                        item = root / fid
                        item.mkdir(mode=0o700, exist_ok=True)
                        source = item / 'original.m4a'
                        if not source.exists():
                            partial = item / 'original.partial'
                            drive.download(meta, partial)
                            partial.replace(source)
                            downloaded += 1
                        validate_bytes(source, meta)
                        write_json(item / 'source.json', {'drive': meta, 'sha256': sha, 'downloaded_at': time.time(), 'review_only': True})
                        database.execute('INSERT OR REPLACE INTO receipts VALUES(?,?,?,?)', (fid, sha, 'downloaded', time.time()))
                        database.commit()
                        if config.get('transcribe', False):
                            if transcribed >= 1:
                                break
                            transcribe(config, source, item)
                            database.execute('UPDATE receipts SET state=?,at=? WHERE id=?', ('review', time.time(), fid))
                            database.execute('DELETE FROM failures WHERE id=?', (fid,))
                            database.commit()
                            transcribed += 1
                        if downloaded >= 3:
                            break
                    except Exception as error:
                        code = str(error) if isinstance(error, SafeError) else 'audio_processing_failed'
                        status['errors'].append(code)
                        fid = meta.get('id', '')
                        database.execute('INSERT INTO failures VALUES(?,?,1,?) ON CONFLICT(id) DO UPDATE SET code=excluded.code,attempts=attempts+1,at=excluded.at', (fid, code, time.time()))
                        database.commit()
                        if len(status['errors']) >= 3:
                            break
                quarantined = database.execute('SELECT COUNT(*) FROM failures WHERE attempts>=3').fetchone()[0]
                status.update(state='needs_review' if status['errors'] or quarantined else 'ready', downloaded=downloaded, transcribed=transcribed, quarantined=quarantined)
            return status
        except Exception as error:
            status.update(state='error', errors=[str(error) if isinstance(error, SafeError) else 'worker_failed'])
            return status
        finally:
            write_json(root / 'status.json', status)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    parser.add_argument('--probe', action='store_true')
    args = parser.parse_args()
    config = load_config(args.config)
    result = run(config, args.probe)
    print(json.dumps(result, ensure_ascii=False))
    return 1 if result['state'] == 'error' else 0

if __name__ == '__main__':
    raise SystemExit(main())
