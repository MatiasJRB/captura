import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from datetime import datetime, timezone, timedelta
import worker

DATA=b'real-test-audio-bytes'*200
FOLDER=dict(id='folder',mimeType='application/vnd.google-apps.folder',shared=False,ownedByMe=True,trashed=False,properties=dict(personalCaptureInbox='1',device='test'))
META=dict(id='audio_1',name='../../escape.m4a',mimeType='audio/mp4',shared=False,ownedByMe=True,trashed=False,parents=['folder'],size=str(len(DATA)),md5Checksum=hashlib.md5(DATA).hexdigest(),properties=dict(personalCaptureAudio='1',sha256=hashlib.sha256(DATA).hexdigest()))
class Fake:
    def __init__(self,config): pass
    def get(self,path,**params): return {'user':{'emailAddress':'test@example.com'}}
    def folder(self,configured): return FOLDER
    def list(self,query): return [META]
    def download(self,meta,path): path.write_bytes(DATA)
class Tests(unittest.TestCase):
    def test_private_scope_and_path_validation(self):
        self.assertEqual(worker.verify_audio(META,'folder'),len(DATA))
        for patch_meta in ({'shared':True},{'ownedByMe':False},{'parents':['other']},{'size':str(worker.MAX_AUDIO+1)}):
            with self.assertRaises(worker.SafeError): worker.verify_audio(dict(META,**patch_meta),'folder')
        with self.assertRaises(worker.SafeError): worker.identifier('../escape')
        with self.assertRaises(worker.SafeError): worker.verify_folder(dict(FOLDER,shared=True))
    def test_checksum_corruption(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'audio'; path.write_bytes(DATA)
            self.assertEqual(worker.validate_bytes(path,META),META['properties']['sha256'])
            path.write_bytes(DATA+b'corruption')
            with self.assertRaises(worker.SafeError): worker.validate_bytes(path,META)
    def test_account_mismatch_and_unpinned_gate(self):
        with tempfile.TemporaryDirectory() as folder:
            config=dict(root=folder,expected_account='wrong@example.com')
            self.assertEqual(worker.run(config,drive_factory=Fake)['errors'],['drive_account_mismatch'])
            config['expected_account']='test@example.com'
            self.assertEqual(worker.run(config,drive_factory=Fake)['state'],'waiting_for_exact_folder_configuration')
            self.assertFalse((Path(folder)/'audio_1').exists())
    def test_dedupe_and_name_never_used_as_path(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(worker,'transcribe') as asr:
            config=dict(root=folder,expected_account='test@example.com',folder_id='folder',transcribe=True)
            first=worker.run(config,drive_factory=Fake)
            second=worker.run(config,drive_factory=Fake)
            self.assertEqual(first['transcribed'],1)
            self.assertEqual(second['transcribed'],0)
            self.assertEqual(asr.call_count,1)
            self.assertEqual((Path(folder)/'audio_1/original.m4a').read_bytes(),DATA)
    def test_probe_does_not_download(self):
        with tempfile.TemporaryDirectory() as folder:
            result=worker.run(dict(root=folder,expected_account='test@example.com'),True,Fake)
            self.assertEqual(result['state'],'private_inbox_verified')
            self.assertFalse((Path(folder)/'audio_1').exists())
    def test_valid_token_reused_and_quota_project_header(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(worker.subprocess,'run') as refresh:
            path=Path(folder)/'rclone.conf'
            token=dict(access_token='test-only',expiry=(datetime.now(timezone.utc)+timedelta(hours=1)).isoformat())
            path.write_text('[gdrive]\ntype = drive\ntoken = '+json.dumps(token)+'\n')
            drive=worker.Drive(dict(remote='gdrive',rclone_config=str(path),quota_project='example-project'))
            refresh.assert_not_called()
            with patch.object(drive.opener,'open') as opened:
                drive.request('about',{'fields':'user(emailAddress)'})
                request=opened.call_args[0][0]
                self.assertEqual(request.get_header('X-goog-user-project'),'example-project')
                self.assertNotIn('test-only',request.full_url)
    def test_failed_item_does_not_starve_good_item(self):
        class Two(Fake):
            def list(self,query): return [dict(META,id='bad'),dict(META,id='good')]
        def asr(config,source,output):
            if output.name=='bad': raise worker.SafeError('asr_output_missing')
        with tempfile.TemporaryDirectory() as folder, patch.object(worker,'transcribe',side_effect=asr):
            config=dict(root=folder,expected_account='test@example.com',folder_id='folder',transcribe=True)
            self.assertEqual(worker.run(config,drive_factory=Two)['transcribed'],1)
            worker.run(config,drive_factory=Two); worker.run(config,drive_factory=Two)
            fourth=worker.run(config,drive_factory=Two)
            self.assertEqual(fourth['quarantined'],1)
            self.assertEqual(fourth['state'],'needs_review')
            self.assertTrue((Path(folder)/'bad/original.m4a').exists())
if __name__=='__main__': unittest.main()
