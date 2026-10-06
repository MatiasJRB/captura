from pathlib import Path
import unittest
import xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1]/'android'
A='{http://schemas.android.com/apk/res/android}'
class AndroidTests(unittest.TestCase):
    def test_dark_start_and_neutral_identity(self):
        for name in ('res/values/styles.xml','res/values-v31/styles.xml'):
            tokens={i.get('name'):i.text for i in ET.parse(ROOT/name).iter('item')}
            self.assertEqual(tokens['android:windowBackground'],'#111815')
            self.assertEqual(tokens['android:windowLightStatusBar'],'false')
        manifest=ET.parse(ROOT/'AndroidManifest.xml')
        self.assertEqual(manifest.find('application').get(A+'label'),'Captura')
        self.assertEqual(manifest.find('application').get(A+'allowBackup'),'false')
        for node in list(manifest.iter('activity'))+list(manifest.iter('service')):
            self.assertTrue(node.get(A+'name').startswith('org.example.captura.'))
    def test_no_historical_signing_requirement(self):
        gradle=(ROOT/'build.gradle').read_text()
        self.assertNotIn('storePassword',gradle)
        self.assertNotIn('.debug.keystore',gradle)
        self.assertIn('captureApplicationId',gradle)
    def test_note_promotes_only_after_encoder_close(self):
        source=(ROOT/'src/org/example/captura/CaptureService.java').read_text()
        close=source.index('completedRecording = voiceEngine.finishFile()')
        promote=source.index('if (finalizeNote && note.active())')
        publish=source.index('done.put(MediaStore.Audio.Media.IS_PENDING, 0)',promote)
        self.assertLess(close,promote)
        self.assertLess(promote,publish)
        self.assertIn('lastChunkCompleted && lastNotePromoted',source)
    def test_visible_permissions_and_mono_icon(self):
        manifest=ET.parse(ROOT/'AndroidManifest.xml')
        permissions={n.get(A+'name') for n in manifest.iter('uses-permission')}
        self.assertIn('android.permission.FOREGROUND_SERVICE_MICROPHONE',permissions)
        self.assertIn('android.permission.RECORD_AUDIO',permissions)
        icon=ET.parse(ROOT/'res/drawable/ic_capture_mono.xml')
        self.assertTrue(all(n.get(A+'fillColor')=='#FFFFFFFF' for n in icon.iter('path')))
if __name__=='__main__':unittest.main()
