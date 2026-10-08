"""Opt-in publishing to Google Docs. Fake opener, temp dirs, fictional data, no network."""
from datetime import timezone, timedelta
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import urllib.parse

import publish
import worker
from test_worker import Fake, META

TOKEN = 'fictional-access-token-value'
ACCOUNT = 'test@example.com'
SHA = 'a' * 64
TZ = timezone(timedelta(hours=-3))
FOLDER = dict(id='transcripts_folder', name=publish.FOLDER_NAME, mimeType=publish.FOLDER_MIME,
              properties={publish.FOLDER_PROPERTY: '1'}, shared=False, ownedByMe=True, trashed=False)


def record(rid='rec_1', segments=None, state=None, **extra):
    segments = [dict(start_ms=0, end_ms=1500, text='hola mundo'),
                dict(start_ms=65000, end_ms=67000, text='segunda idea')] if segments is None else segments
    data = dict(schema_version=1, id=rid, review_only=True,
                state=state or ('needs_review' if segments else 'no_speech_detected'),
                language='es', recorded_at=None, processed_at='2026-10-08T15:04:00+00:00',
                original=dict(path='original.m4a', sha256=SHA),
                transcript=dict(text=' '.join(s['text'] for s in segments), segments=segments),
                engine=dict(name='whisper.cpp', model='ggml-fictional.bin', vad=True), speaker_verified=False)
    data.update(extra)
    return data


def inbox(tmp, *records, names=None):
    root = Path(tmp) / 'inbox'
    root.mkdir(exist_ok=True)
    for data in records:
        item = root / data['id']
        item.mkdir()
        (item / 'record.json').write_text(json.dumps(data))
        name = (names or {}).get(data['id'])
        if name:
            (item / 'source.json').write_text(json.dumps(dict(drive=dict(name=name))))
    return root


class Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


class FakeDrive:
    """A fake opener that answers like Drive and remembers what was sent."""

    def __init__(self, folders=(), docs=(), account=ACCOUNT, fail=None):
        self.folders, self.docs, self.account, self.fail = list(folders), list(docs), account, fail
        self.requests = []

    def open(self, request, timeout=None):
        url = urllib.parse.urlsplit(request.full_url)
        params = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        self.requests.append(dict(method=request.get_method(), path=url.path, params=params,
                                  headers=dict(request.header_items()), body=request.data, url=request.full_url))
        if self.fail:
            code, text = self.fail
            raise urllib.error.HTTPError(request.full_url, code, 'error', {}, io.BytesIO(text))
        method, path = request.get_method(), url.path
        if path == '/drive/v3/about':
            answer = dict(user=dict(emailAddress=self.account))
        elif method == 'GET' and path == '/drive/v3/files':
            query = params['q']
            if 'captureRecordId' in query:
                answer = dict(files=[d for d in self.docs if "value='" + d['properties']['captureRecordId'] + "'" in query])
            else:
                answer = dict(files=self.folders)
        elif method == 'GET' and path.startswith('/drive/v3/files/'):
            found = [f for f in self.folders if f['id'] == path.rsplit('/', 1)[1]]
            if not found:
                raise urllib.error.HTTPError(request.full_url, 404, 'missing', {}, io.BytesIO(b'{}'))
            answer = found[0]
        elif method == 'POST' and path == '/drive/v3/files':
            meta = json.loads(request.data)
            answer = dict(FOLDER, id='new_folder', name=meta['name'], properties=meta['properties'])
            self.folders.append(answer)
        elif method == 'POST' and path == '/upload/drive/v3/files':
            meta = json.loads(parts(request)[0][1])
            answer = dict(id='doc_' + str(len(self.docs) + 1), name=meta['name'], mimeType=meta['mimeType'],
                          parents=meta['parents'], properties=meta['properties'])
            self.docs.append(answer)
        else:
            raise AssertionError('unexpected request ' + method + ' ' + path)
        return Response(json.dumps(answer).encode())

    def writes(self):
        return [r for r in self.requests if r['method'] != 'GET']


def parts(request):
    """[(content type, text)] of a multipart/related request."""
    boundary = dict(request.header_items())['Content-type'].split('boundary=')[1]
    chunks = request.data.decode('utf-8').split('--' + boundary)
    assert chunks[-1] == '--\r\n', chunks[-1]
    result = []
    for chunk in chunks[1:-1]:
        head, text = chunk.strip('\r\n').split('\r\n\r\n', 1)
        result.append((head.split(': ', 1)[1], text))
    return result


def factory(drive):
    return lambda config: publish.Writer(config, opener=drive, token=TOKEN)


def config(root, **extra):
    return dict(root=str(root), expected_account=ACCOUNT, **extra)


class AllowlistTests(unittest.TestCase):
    def test_only_listed_routes_on_googleapis(self):
        good = [('GET', 'https://www.googleapis.com/drive/v3/about?fields=user'),
                ('GET', 'https://www.googleapis.com/drive/v3/files?q=x&fields=y&pageSize=100'),
                ('GET', 'https://www.googleapis.com/drive/v3/files/abc_DEF-1?fields=id'),
                ('POST', 'https://www.googleapis.com/drive/v3/files?fields=id'),
                ('POST', 'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id')]
        for method, url in good:
            with self.subTest(url=url):
                self.assertTrue(publish.allowed(method, url))
        bad = [('GET', 'https://evil.example/drive/v3/files'),
               ('GET', 'http://www.googleapis.com/drive/v3/files'),
               ('GET', 'https://www.googleapis.com:8443/drive/v3/files'),
               ('GET', 'https://user@www.googleapis.com/drive/v3/files'),
               ('GET', 'https://www.googleapis.com.evil.example/drive/v3/files'),
               ('DELETE', 'https://www.googleapis.com/drive/v3/files/abc'),
               ('PATCH', 'https://www.googleapis.com/drive/v3/files/abc?fields=id'),
               ('PUT', 'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart'),
               ('POST', 'https://www.googleapis.com/drive/v3/files/abc/permissions'),
               ('POST', 'https://www.googleapis.com/drive/v3/files/abc/copy'),
               ('GET', 'https://www.googleapis.com/drive/v3/files/abc?alt=media'),
               ('GET', 'https://www.googleapis.com/drive/v3/files/..%2Fabout'),
               ('POST', 'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable'),
               ('POST', 'https://www.googleapis.com/upload/drive/v3/files'),
               ('POST', 'https://www.googleapis.com/drive/v3/files?addParents=x'),
               ('GET', 'https://www.googleapis.com/drive/v3/files?fields=a&fields=b'),
               ('GET', 'https://www.googleapis.com/drive/v3/about#frag'),
               ('GET', 'https://www.googleapis.com/gmail/v1/users/me/messages')]
        for method, url in bad:
            with self.subTest(method=method, url=url):
                self.assertFalse(publish.allowed(method, url))

    def test_writer_refuses_before_sending(self):
        drive = FakeDrive()
        writer = publish.Writer({}, opener=drive, token=TOKEN)
        for method, path in (('DELETE', '/drive/v3/files/abc'), ('PATCH', '/drive/v3/files/abc'),
                             ('POST', '/drive/v3/files/abc/permissions')):
            with self.assertRaisesRegex(worker.SafeError, 'publish_request_not_allowed'):
                writer.call(method, path)
        self.assertEqual(drive.requests, [])

    def test_token_reuses_rclone_helper(self):
        with patch.object(worker, 'drive_token', return_value=TOKEN) as helper:
            writer = publish.Writer(dict(quota_project='example-project'), opener=FakeDrive())
            helper.assert_called_once()
            writer.account()
        request = writer.opener.requests[0]
        self.assertEqual(request['headers']['Authorization'], 'Bearer ' + TOKEN)
        self.assertEqual(request['headers']['X-goog-user-project'], 'example-project')
        self.assertNotIn(TOKEN, request['url'])


class FolderTests(unittest.TestCase):
    def test_creates_private_folder_and_remembers_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = inbox(tmp, record())
            drive = FakeDrive()
            result = publish.publish(config(root), writer_factory=factory(drive), tz=TZ)
            self.assertEqual(result['state'], 'published', result)
            create = [r for r in drive.requests if r['path'] == '/drive/v3/files' and r['method'] == 'POST'][0]
            meta = json.loads(create['body'])
            self.assertEqual(meta, dict(name='Captura · transcripciones', mimeType=publish.FOLDER_MIME,
                                        properties={'personalCaptureTranscripts': '1'}))
            self.assertNotIn('parents', meta)
            state_path = root / 'published.json'
            self.assertEqual(json.loads(state_path.read_text())['folder_id'], 'new_folder')
            self.assertEqual(stat.S_IMODE(state_path.stat().st_mode), 0o600)
            self.assertFalse((root / 'published.tmp').exists())

    def test_reuses_folder_found_by_property_not_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = inbox(tmp, record())
            drive = FakeDrive(folders=[dict(FOLDER, name='renamed by the person')])
            publish.publish(config(root), writer_factory=factory(drive), tz=TZ)
            search = [r for r in drive.requests if r['path'] == '/drive/v3/files' and r['method'] == 'GET'][0]
            self.assertIn("key='personalCaptureTranscripts' and value='1'", search['params']['q'])
            self.assertNotIn('name', search['params']['q'])
            self.assertFalse([r for r in drive.requests if r['path'] == '/drive/v3/files' and r['method'] == 'POST'])
            self.assertEqual(drive.docs[0]['parents'], ['transcripts_folder'])

    def test_remembered_folder_is_rechecked_by_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = inbox(tmp, record('rec_1'))
            drive = FakeDrive(folders=[FOLDER])
            publish.publish(config(root), writer_factory=factory(drive), tz=TZ)
            inbox(tmp, record('rec_2'))
            drive.requests.clear()
            publish.publish(config(root), writer_factory=factory(drive), tz=TZ)
            self.assertIn('/drive/v3/files/transcripts_folder', [r['path'] for r in drive.requests])

    def test_refuses_shared_not_owned_trashed_and_ambiguous(self):
        cases = [(dict(FOLDER, shared=True), 'transcripts_folder_shared'),
                 (dict(FOLDER, ownedByMe=False), 'transcripts_folder_not_owned'),
                 (dict(FOLDER, mimeType='text/plain'), 'transcripts_folder_invalid')]
        for folder, code in cases:
            with self.subTest(code=code), tempfile.TemporaryDirectory() as tmp:
                root = inbox(tmp, record())
                drive = FakeDrive(folders=[folder])
                result = publish.publish(config(root), writer_factory=factory(drive), tz=TZ)
                self.assertEqual(result['state'], 'error')
                self.assertEqual(result['errors'], [dict(error=code)])
                self.assertEqual(drive.writes(), [])
                self.assertFalse((root / 'published.json').exists())
        with tempfile.TemporaryDirectory() as tmp:
            root = inbox(tmp, record())
            drive = FakeDrive(folders=[FOLDER, dict(FOLDER, id='other')])
            self.assertEqual(publish.publish(config(root), writer_factory=factory(drive))['errors'],
                             [dict(error='ambiguous_transcript_folders')])
            self.assertEqual(drive.writes(), [])

    def test_remembered_folder_shared_later_or_gone_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = inbox(tmp, record('rec_1'))
            drive = FakeDrive(folders=[FOLDER])
            publish.publish(config(root), writer_factory=factory(drive), tz=TZ)
            inbox(tmp, record('rec_2'))
            drive.folders = [dict(FOLDER, shared=True)]
            self.assertEqual(publish.publish(config(root), writer_factory=factory(drive))['errors'],
                             [dict(error='transcripts_folder_shared')])
            drive.folders = []
            self.assertEqual(publish.publish(config(root), writer_factory=factory(drive))['errors'],
                             [dict(error='transcripts_folder_missing')])
            self.assertEqual(len(drive.docs), 1)

    def test_account_mismatch_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = inbox(tmp, record())
            drive = FakeDrive(account='other@example.com')
            result = publish.publish(config(root), writer_factory=factory(drive))
            self.assertEqual(result['errors'], [dict(error='drive_account_mismatch')])
            self.assertEqual(drive.writes(), [])


class DocTests(unittest.TestCase):
    def test_multipart_body_converts_text_to_doc_with_properties(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = inbox(tmp, record(), names={'rec_1': 'Grabación 2026-10-08.m4a'})
            drive = FakeDrive(folders=[FOLDER])
            result = publish.publish(config(root), writer_factory=factory(drive), tz=TZ)
            upload = [r for r in drive.requests if r['path'] == '/upload/drive/v3/files'][0]
            self.assertEqual(upload['params']['uploadType'], 'multipart')
            self.assertTrue(upload['headers']['Content-type'].startswith('multipart/related; boundary='))
            from urllib.request import Request
            request = Request(upload['url'], data=upload['body'], headers=upload['headers'], method='POST')
            (meta_type, meta_text), (text_type, text) = parts(request)
            self.assertEqual(meta_type, 'application/json; charset=UTF-8')
            self.assertEqual(text_type, 'text/plain; charset=UTF-8')
            meta = json.loads(meta_text)
            self.assertEqual(meta['mimeType'], 'application/vnd.google-apps.document')
            self.assertEqual(meta['parents'], ['transcripts_folder'])
            self.assertEqual(meta['properties'], dict(captureRecordId='rec_1', captureOriginalSha256=SHA))
            self.assertEqual(meta['name'], '2026-10-08 12:04 · Grabación 2026-10-08.m4a')
            self.assertIn('[01:05] segunda idea', text)
            self.assertEqual(result['docs'], [dict(id='rec_1', title=meta['name'],
                                                   url='https://docs.google.com/document/d/doc_1/edit')])

    def test_title_and_body_format(self):
        data = record(segments=[dict(start_ms=0, end_ms=900, text='  hola\x07 <b>mundo</b>  '),
                                dict(start_ms=3725000, end_ms=3726000, text='línea\ncon salto')])
        self.assertEqual(publish.title(data, None, TZ), '2026-10-08 12:04 · rec_1')
        self.assertEqual(publish.title(dict(data, recorded_at='2026-10-07T23:30:00Z'), 'a.m4a', TZ),
                         '2026-10-07 20:30 · a.m4a')
        text = publish.body(data, 'nota\nrara.m4a', TZ).splitlines()
        self.assertEqual(text[0], 'Transcripción automática de Captura — borrador a revisar. '
                                  'Puede tener errores y no identifica quién habla.')
        self.assertIn('Audio: nota rara.m4a', text)
        self.assertIn('ID del registro: rec_1', text)
        self.assertIn('Fecha: 2026-10-08 12:04 (transcripción)', text)
        self.assertIn('Idioma: es', text)
        self.assertIn('Modelo: ggml-fictional.bin (whisper.cpp, con detección de voz)', text)
        self.assertIn('[00:00] hola <b>mundo</b>', text)
        self.assertIn('[62:05] línea con salto', text)
        self.assertNotIn('\x07', '\n'.join(text))

    def test_audio_name_from_source_is_one_clean_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = inbox(tmp, record(), names={'rec_1': '../../evil\nname\x00.m4a'})
            self.assertEqual(publish.audio_name(root, 'rec_1'), '../../evil name .m4a')
            self.assertIsNone(publish.audio_name(root, 'missing'))

    def test_no_speech_skipped_unless_included(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = inbox(tmp, record('silent', segments=[]))
            drive = FakeDrive(folders=[FOLDER])
            result = publish.publish(config(root), writer_factory=factory(drive))
            self.assertEqual((result['state'], result['published'], result['skipped_empty']),
                             ('nothing_to_publish', 0, 1))
            self.assertEqual(drive.requests, [])
            result = publish.publish(config(root), include_empty=True, writer_factory=factory(drive), tz=TZ)
            self.assertEqual(result['published'], 1)
            from urllib.request import Request
            upload = [r for r in drive.requests if r['path'] == '/upload/drive/v3/files'][0]
            text = parts(Request(upload['url'], data=upload['body'], headers=upload['headers']))[1][1]
            self.assertIn(publish.NO_SPEECH, text)


class IdempotencyTests(unittest.TestCase):
    def test_existing_remote_doc_is_not_duplicated(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = inbox(tmp, record())
            drive = FakeDrive(folders=[FOLDER], docs=[dict(id='doc_old', properties=dict(captureRecordId='rec_1'))])
            result = publish.publish(config(root), writer_factory=factory(drive))
            self.assertEqual((result['published'], result['skipped']), (0, 1))
            self.assertFalse([r for r in drive.requests if r['path'].startswith('/upload/')])
            query = [r['params']['q'] for r in drive.requests if 'captureRecordId' in r['params'].get('q', '')][0]
            self.assertIn("'transcripts_folder' in parents", query)
            receipt = json.loads((root / 'published.json').read_text())['records']['rec_1']
            self.assertEqual((receipt['doc_id'], receipt['sha256']), ('doc_old', SHA))

    def test_local_receipt_means_no_network_on_rerun(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = inbox(tmp, record())
            publish.publish(config(root), writer_factory=factory(FakeDrive(folders=[FOLDER])))

            def no_network(config):
                raise AssertionError('no token or network expected')
            result = publish.publish(config(root), writer_factory=no_network)
            self.assertEqual((result['state'], result['skipped']), ('nothing_to_publish', 1))

    def test_changed_original_is_reported_not_republished(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = inbox(tmp, record())
            drive = FakeDrive(folders=[FOLDER])
            publish.publish(config(root), writer_factory=factory(drive))
            data = record(original=dict(path='original.m4a', sha256='b' * 64))
            (root / 'rec_1/record.json').write_text(json.dumps(data))
            result = publish.publish(config(root), writer_factory=factory(drive))
            self.assertEqual(result['errors'], [dict(id='rec_1', error='published_record_changed')])
            self.assertEqual(len(drive.docs), 1)

    def test_dry_run_is_offline_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = inbox(tmp, record('rec_1'), record('silent', segments=[]))
            before = sorted(p.name for p in root.rglob('*'))

            def no_network(config):
                raise AssertionError('dry run must stay offline')
            result = publish.publish(config(root), dry_run=True, writer_factory=no_network, tz=TZ)
            self.assertEqual(result['state'], 'dry_run')
            self.assertEqual(result['would_publish'], [dict(id='rec_1', title='2026-10-08 12:04 · rec_1')])
            self.assertEqual(result['skipped_empty'], 1)
            self.assertEqual(sorted(p.name for p in root.rglob('*')), before)

    def test_other_account_state_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = inbox(tmp, record())
            publish.publish(config(root), writer_factory=factory(FakeDrive(folders=[FOLDER])))
            inbox(tmp, record('rec_2'))
            result = publish.publish(dict(config(root), expected_account='new@example.com'),
                                     writer_factory=factory(FakeDrive(account='new@example.com')))
            self.assertEqual(result['errors'], [dict(error='publish_state_other_account')])


class ErrorTests(unittest.TestCase):
    def test_http_errors_are_sanitized(self):
        cases = [((401, b'secret body ' + TOKEN.encode()), 'publish_http_401'),
                 ((429, b'slow'), 'publish_rate_limit_retry_later'),
                 ((403, b'{"reason":"insufficientPermissions"}'), 'publish_needs_drive_file_scope'),
                 ((500, b'server ' + TOKEN.encode()), 'publish_http_500')]
        for fail, code in cases:
            with self.subTest(code=code), tempfile.TemporaryDirectory() as tmp:
                root = inbox(tmp, record())
                result = publish.publish(config(root), writer_factory=factory(FakeDrive(fail=fail)))
                self.assertEqual(result['errors'], [dict(error=code)])
                self.assertNotIn(TOKEN, json.dumps(result))
                self.assertNotIn('secret body', json.dumps(result))

    def test_connection_failure_hides_details(self):
        class Broken:
            def open(self, request, timeout=None):
                raise OSError('connect failed with Bearer ' + TOKEN)
        with tempfile.TemporaryDirectory() as tmp:
            root = inbox(tmp, record())
            result = publish.publish(config(root), writer_factory=lambda c: publish.Writer(c, Broken(), TOKEN))
            self.assertEqual(result['errors'], [dict(error='publish_connection_failed')])
            self.assertNotIn(TOKEN, json.dumps(result))

    def test_unexpected_exception_is_generic(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = inbox(tmp, record())

            def explode(config):
                raise RuntimeError('token ' + TOKEN)
            result = publish.publish(config(root), writer_factory=explode)
            self.assertEqual(result['errors'], [dict(error='publish_failed')])
            self.assertNotIn(TOKEN, json.dumps(result))


DATA = b'real-test-audio-bytes' * 200


class RunIntegrationTests(unittest.TestCase):
    def test_run_then_publish_when_enabled(self):
        def asr(config, source, output):
            worker.write_json(output / 'record.json', record(output.name, original=dict(
                path='original.m4a', sha256=hashlib.sha256(source.read_bytes()).hexdigest())))
        with tempfile.TemporaryDirectory() as tmp, patch.object(worker, 'transcribe', side_effect=asr):
            cfg = dict(root=str(Path(tmp) / 'inbox'), expected_account=ACCOUNT, folder_id='folder', transcribe=True)
            drive = FakeDrive()
            status = worker.run(cfg, drive_factory=Fake)
            self.assertIsNone(publish.after_run(cfg, status, writer_factory=factory(drive)))
            self.assertEqual(drive.requests, [])
            cfg['publish'] = True
            result = publish.after_run(cfg, status, writer_factory=factory(drive))
            self.assertEqual((result['state'], result['published']), ('published', 1))
            meta = drive.docs[0]
            self.assertEqual(meta['properties']['captureRecordId'], 'audio_1')
            self.assertEqual(meta['properties']['captureOriginalSha256'], META['properties']['sha256'])
            self.assertTrue(meta['name'].endswith(' · ../../escape.m4a'))
            self.assertFalse(any(r['path'].startswith('/upload/') and b'real-test-audio' in r['body']
                                 for r in drive.requests))
            self.assertIsNone(publish.after_run(cfg, dict(state='error'), writer_factory=factory(drive)))


if __name__ == '__main__':
    unittest.main()
