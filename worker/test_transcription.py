import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import worker

class TranscriptionTests(unittest.TestCase):
    def setup_case(self,tmp):
        item=Path(tmp)/'record_1';item.mkdir()
        source=item/'original.m4a';source.write_bytes(b'fake-original')
        vad=Path(tmp)/'vad.bin';vad.write_bytes(b'fake-model')
        config=dict(ffmpeg='fake-ffmpeg',whisper='fake-whisper',model='fake-model.bin',vad_model=str(vad))
        return item,source,config
    def runner(self,segments):
        def run(command,**kwargs):
            if command[0]=='fake-ffmpeg':Path(command[-1]).write_bytes(b'wav')
            else:
                self.assertIn('--vad',command);self.assertIn('--vad-model',command)
                prefix=Path(command[command.index('-of')+1])
                prefix.with_suffix('.txt').write_text('candidate')
                prefix.with_suffix('.json').write_text(json.dumps({'transcription':segments}))
                prefix.with_suffix('.srt').write_text('')
        return run
    def test_vad_is_required_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            item,source,config=self.setup_case(tmp);del config['vad_model']
            with patch.object(worker.subprocess,'run') as run:
                with self.assertRaisesRegex(worker.SafeError,'vad_model_required'):worker.transcribe(config,source,item)
                run.assert_not_called()
    def test_valid_empty_output_is_not_endless_silence_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            item,source,config=self.setup_case(tmp)
            with patch.object(worker.subprocess,'run',side_effect=self.runner([])):worker.transcribe(config,source,item)
            data=json.loads((item/'record.json').read_text())
            self.assertEqual(data['state'],'no_speech_detected');self.assertTrue(data['review_only'])
            self.assertFalse(data['speaker_verified']);self.assertEqual(source.read_bytes(),b'fake-original')
            self.assertFalse(list(item.glob('.asr-*')))
    def test_timestamps_record_and_clean_scratch(self):
        with tempfile.TemporaryDirectory() as tmp:
            item,source,config=self.setup_case(tmp)
            segments=[dict(offsets={'from':0,'to':1250},text=' idea ')]
            with patch.object(worker.subprocess,'run',side_effect=self.runner(segments)):worker.transcribe(config,source,item)
            data=json.loads((item/'record.json').read_text())
            self.assertEqual(data['transcript']['segments'],[dict(start_ms=0,end_ms=1250,text='idea')])
            self.assertIsNone(data['recorded_at']);self.assertEqual(data['state'],'needs_review')
    def test_exit_zero_help_cannot_accept_stale_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            item,source,config=self.setup_case(tmp)
            (item/'transcript.txt').write_text('stale')
            (item/'transcript.json').write_text('{"transcription":[]}')
            with patch.object(worker.subprocess,'run'):
                with self.assertRaisesRegex(worker.SafeError,'asr_output_missing'):worker.transcribe(config,source,item)
            self.assertFalse((item/'record.json').exists())
    def test_invalid_offsets_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            item,source,config=self.setup_case(tmp)
            with patch.object(worker.subprocess,'run',side_effect=self.runner([dict(offsets={'from':-1,'to':2},text='bad')])):
                with self.assertRaisesRegex(worker.SafeError,'asr_invalid_json'):worker.transcribe(config,source,item)
if __name__=='__main__':unittest.main()
