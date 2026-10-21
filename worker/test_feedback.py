"""Metadata roundtrip and writer boundaries, using fictional records only."""
import copy
import json
import io
from pathlib import Path
import sqlite3
import tempfile
import urllib.parse
import unittest
from unittest.mock import patch

import feedback
from worker import SafeError

SHA = 'a' * 64


class FakeWriter:
    def __init__(self):
        self.files = []
        self.sent = []
        self.folder = dict(id='phoneFolder', mimeType='application/vnd.google-apps.folder',
                           shared=False, ownedByMe=True, trashed=False,
                           properties=dict(personalCaptureInbox='1', device='test-device'))

    def account(self): return 'test@example.com'
    def folder_by_id(self, fid): return copy.deepcopy(self.folder)
    def find_reports(self, fid): return copy.deepcopy(self.files)
    def create_report(self, folder, device, payload):
        self.sent.append(payload)
        self.files = [dict(id='reportID', mimeType='application/json', parents=[folder],
                           shared=False, ownedByMe=True, trashed=False,
                           properties=dict(personalCaptureFeedback='1', sourceFolder=folder, device=device))]
        return self.files[0]
    def update_report(self, meta, payload): self.sent.append(payload)


class FeedbackTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = dict(root=str(self.root), folder_id='phoneFolder',
                           expected_account='test@example.com', feedback=True)
        with sqlite3.connect(self.root / 'receipts.sqlite') as db:
            db.execute('CREATE TABLE receipts(id TEXT,sha TEXT,state TEXT,at REAL)')
            db.execute('CREATE TABLE failures(id TEXT,attempts INTEGER)')
            db.execute('INSERT INTO receipts VALUES(?,?,?,?)', ('audioID', SHA, 'review', 1000))
        item = self.root / 'audioID'; item.mkdir()
        (item / 'source.json').write_text(json.dumps(dict(sha256=SHA, drive=dict(parents=['phoneFolder']))))
        (item / 'transcript.txt').write_text('Fictional transcript, never sent')
        (item / 'transcript.json').write_text('{}')
        self.writer = FakeWriter()

    def test_snapshot_has_no_text_and_exact_identity(self):
        report = feedback.snapshot(self.config, 'test-device', now=1000)
        self.assertEqual([dict(id='audioID', sha256=SHA, state='transcribed')], report['records'])
        self.assertNotIn('Fictional', json.dumps(report))
        self.assertEqual('phoneFolder', report['folder_id'])
        fixture = Path(__file__).resolve().parents[1]/'tests/fixtures/worker-feedback/report.json'
        self.assertEqual(json.loads(fixture.read_text()), report)

    def test_other_folder_or_hash_is_omitted(self):
        for source in [dict(sha256=SHA, drive=dict(parents=['other'])),
                       dict(sha256='b'*64, drive=dict(parents=['phoneFolder']))]:
            (self.root/'audioID/source.json').write_text(json.dumps(source))
            self.assertEqual([], feedback.snapshot(self.config, 'test-device')['records'])

    def test_missing_asr_cannot_be_transcribed(self):
        (self.root/'audioID/transcript.txt').unlink()
        self.assertEqual([], feedback.snapshot(self.config, 'test-device')['records'])

    def test_pending_failure_is_error(self):
        with sqlite3.connect(self.root/'receipts.sqlite') as db:
            db.execute("UPDATE receipts SET state='downloaded'")
            db.execute("INSERT INTO failures VALUES('audioID',2)")
        self.assertEqual('error', feedback.snapshot(self.config, 'test-device')['records'][0]['state'])

    def test_default_off_and_dry_run_never_construct_network_writer(self):
        with patch.object(feedback, 'Writer', side_effect=AssertionError('network')):
            self.assertEqual('disabled', feedback.publish(dict(self.config, feedback=False))['state'])
            self.assertEqual('preview', feedback.publish(self.config, dry_run=True)['state'])

    def test_after_run_reports_failure_without_losing_transcription_state(self):
        with patch.object(feedback, 'publish', side_effect=SafeError('feedback_http_503')):
            self.assertEqual('feedback_http_503', feedback.after_run(self.config)['error'])
            self.assertIsNone(feedback.after_run(dict(self.config, feedback=False)))

    def test_retry_updates_one_report_not_another_audio(self):
        for _ in range(2):
            self.assertEqual('published', feedback.publish(self.config, writer=self.writer)['state'])
        self.assertEqual(1, len(self.writer.files))
        self.assertEqual(2, len(self.writer.sent))

    def test_wrong_account_shared_folder_duplicate_or_foreign_report_rejected(self):
        feedback.publish(self.config, writer=self.writer)
        valid = copy.deepcopy(self.writer.files)
        for change in ['account','folder','duplicate','report']:
            self.writer = FakeWriter(); self.writer.files = copy.deepcopy(valid)
            if change == 'account': self.writer.account = lambda: 'other@example.com'
            if change == 'folder': self.writer.folder['shared'] = True
            if change == 'duplicate': self.writer.files *= 2
            if change == 'report': self.writer.files[0]['parents'] = ['other']
            with self.subTest(change=change), self.assertRaises(SafeError):
                feedback.publish(self.config, writer=self.writer)
            self.assertEqual([], self.writer.sent)

    def test_writer_allowlist_cannot_modify_audio_or_metadata(self):
        self.assertFalse(feedback.allowed('DELETE', 'https://www.googleapis.com/drive/v3/files/audioID'))
        self.assertFalse(feedback.allowed('PATCH', 'https://www.googleapis.com/drive/v3/files/audioID'))
        self.assertFalse(feedback.allowed('PATCH', 'https://evil.example/upload/drive/v3/files/reportID?uploadType=media'))
        self.assertTrue(feedback.allowed('PATCH', 'https://www.googleapis.com/upload/drive/v3/files/reportID?uploadType=media&fields=id'))

    def test_real_writer_transport_creates_then_updates_only_its_json(self):
        fixture = FakeWriter()
        fixture.create_report('phoneFolder', 'test-device', {})
        report = fixture.files[0]
        outer = self

        class Opener:
            def __init__(self): self.exists = False; self.calls = []
            def open(self, request, timeout=None):
                path = urllib.parse.urlsplit(request.full_url).path
                method = request.get_method(); self.calls.append((method,path))
                outer.assertEqual('Bearer fictional-token', request.get_header('Authorization'))
                if path.endswith('/about'): result = dict(user=dict(emailAddress='test@example.com'))
                elif path.endswith('/phoneFolder'): result = fixture.folder
                elif path == '/drive/v3/files': result = dict(files=[report] if self.exists else [])
                elif path == '/drive/v3/files/reportID': result = report
                elif method == 'POST' and path == '/upload/drive/v3/files':
                    self.exists = True
                    outer.assertIn(b'application/json', request.data)
                    outer.assertNotIn(b'Fictional transcript', request.data)
                    result = report
                elif method == 'PATCH' and path == '/upload/drive/v3/files/reportID':
                    outer.assertEqual('phoneFolder', json.loads(request.data)['folder_id'])
                    result = dict(id='reportID')
                else: raise AssertionError('unexpected request')
                return io.BytesIO(json.dumps(result).encode())

        opener = Opener()
        writer = feedback.Writer(self.config, opener=opener, token='fictional-token')
        for _ in range(2): feedback.publish(self.config, writer=writer)
        self.assertEqual(1, opener.calls.count(('POST','/upload/drive/v3/files')))
        self.assertEqual(1, opener.calls.count(('PATCH','/upload/drive/v3/files/reportID')))


if __name__ == '__main__': unittest.main()
