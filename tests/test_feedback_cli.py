"""Setup and dry-run remain offline, with temporary fictional configuration."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FeedbackCLITests(unittest.TestCase):
    def test_opt_in_roundtrip_and_offline_preview(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp)/'config.json'
            config.write_text(json.dumps(dict(root=temp, folder_id='phoneFolder',
                expected_account='test@example.com', remote='fictional',
                rclone_config=str(Path(temp)/'does-not-exist.conf'), rclone='does-not-exist')))
            def run(*args):
                result = subprocess.run([sys.executable,str(ROOT/'bin/capture'),*args,'--config',str(config)],
                                        capture_output=True,text=True)
                self.assertEqual(0,result.returncode,result.stderr+result.stdout)
                return json.loads(result.stdout)
            self.assertEqual('disabled',run('feedback')['state'])
            self.assertFalse(run('feedback','--dry-run')['network'])
            run('set','--feedback','on')
            self.assertTrue(json.loads(config.read_text())['feedback'])
            self.assertTrue(run('feedback','--dry-run')['enabled'])
            run('set','--feedback','off')
            self.assertEqual('disabled',run('feedback')['state'])
