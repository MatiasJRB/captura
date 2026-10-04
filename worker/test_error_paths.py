from datetime import datetime,timezone,timedelta
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import io
import worker
from test_worker import Fake,META
class ErrorPaths(unittest.TestCase):
    def test_missing_auth_is_sanitized(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg=dict(remote='capture',rclone_config=str(Path(tmp)/'missing'),rclone='fake')
            with self.assertRaisesRegex(worker.SafeError,'existing_drive_authorization_unavailable'):worker.Drive(cfg)
    def test_expired_refresh_failure_is_sanitized(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'rclone.conf';p.write_text('[capture]\ntype = drive\ntoken = '+json.dumps(dict(access_token='fake',expiry=(datetime.now(timezone.utc)-timedelta(hours=1)).isoformat()))+'\n')
            with patch.object(worker.subprocess,'run',side_effect=RuntimeError('secret-runtime-text')):
                with self.assertRaisesRegex(worker.SafeError,'existing_drive_authorization_unavailable'):
                    worker.Drive(dict(remote='capture',rclone_config=str(p),rclone='fake'))
    def test_http_revoked_and_rate_limit(self):
        drive=object.__new__(worker.Drive);drive.token='fake';drive.quota_project=None
        from unittest.mock import Mock
        drive.opener=Mock()
        for status,body,expected in [(401,b'private response','drive_http_401'),(429,b'private response','drive_rate_limit_retry_later')]:
            drive.opener.open.side_effect=urllib.error.HTTPError('https://www.googleapis.com',status,'error',{},io.BytesIO(body))
            with self.assertRaisesRegex(worker.SafeError,expected):drive.request('about',{})
    def test_changed_remote_receipt_rejected(self):
        class Changed(Fake):
            def list(self,query):return [dict(META,properties=dict(personalCaptureAudio='1',sha256='0'*64))]
        with tempfile.TemporaryDirectory() as tmp,patch.object(worker,'transcribe'):
            cfg=dict(root=tmp,expected_account='test@example.com',folder_id='folder',transcribe=True)
            worker.run(cfg,drive_factory=Fake)
            second=worker.run(cfg,drive_factory=Changed)
            self.assertEqual(second['errors'],['accepted_remote_audio_changed'])
if __name__=='__main__':unittest.main()
