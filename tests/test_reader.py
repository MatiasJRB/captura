import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'worker'))
import reader
from worker import SafeError
ROOT=Path(__file__).resolve().parents[1]
DEMO=ROOT/'examples/demo'

class ReaderTests(unittest.TestCase):
    def test_demo_is_explicitly_fictional_and_review_only(self):
        record=reader.read(DEMO,'demo_idea')
        self.assertTrue(record['review_only'])
        self.assertFalse(record['speaker_verified'])
        self.assertIsNone(record['original']['path'])
        self.assertEqual(record['engine']['name'],'fictional_hand_authored_demo')
    def test_cli_json_and_no_network_read(self):
        result=subprocess.run([sys.executable,str(ROOT/'bin/capture'),'list','--root',str(DEMO)],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(len(json.loads(result.stdout)['records']),1)
    def test_escape_search_and_export_boundaries(self):
        with tempfile.TemporaryDirectory() as tmp:
            inbox=Path(tmp)/'inbox';item=inbox/'record_1';item.mkdir(parents=True)
            data=reader.read(DEMO,'demo_idea');data['id']='record_1'
            data['transcript']['segments'][0]['text']='<script>attack()</script>'
            (item/'record.json').write_text(json.dumps(data))
            output=Path(tmp)/'view'
            reader.view(inbox,output)
            page=(output/'index.html').read_text()
            self.assertIn('&lt;script&gt;attack()',page)
            self.assertNotIn('<script>attack()',page)
            self.assertIn('color-scheme:dark',page)
            self.assertIn('role="status" aria-live="polite" aria-atomic="true"',page)
            self.assertNotIn('$records',page)
            with self.assertRaises(SafeError):reader.view(inbox,output)
            with self.assertRaises(SafeError):reader.view(inbox,inbox/'export')
            with self.assertRaises(SafeError):reader.read(inbox,'../escape')
    def test_symlinks_schema_and_invalid_are_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'outside').symlink_to(DEMO/'demo_idea',target_is_directory=True)
            with self.assertRaises(SafeError):reader.read(root,'outside')
            bad=root/'bad';bad.mkdir();(bad/'record.json').write_text('{}')
            data=reader.records(root)
            self.assertEqual(len(data['records']),0)
            self.assertEqual(len(data['errors']),2)
    def test_empty_reader_view(self):
        with tempfile.TemporaryDirectory() as tmp:
            inbox=Path(tmp)/'inbox';inbox.mkdir();output=Path(tmp)/'view'
            reader.view(inbox,output)
            self.assertIn('Todavía no hay transcripciones',(output/'index.html').read_text())
if __name__=='__main__':unittest.main()
