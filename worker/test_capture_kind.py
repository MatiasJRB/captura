import unittest
from capture_kind import capture_kind
class CaptureKindTests(unittest.TestCase):
 def test_marker_needs_name_and_property(self):
  name='personal-capture-note-12345678-1234-1234-1234-123456789abc.m4a'
  self.assertEqual(capture_kind({'name':name,'properties':{'captureKind':'dictated_note'}}),'dictated_note')
  self.assertEqual(capture_kind({'name':name}),'ambient_audio')
  self.assertEqual(capture_kind({'name':'normal.m4a','properties':{'captureKind':'dictated_note'}}),'ambient_audio')
 def test_interrupted_not_a_completed_note(self):
  name='personal-capture-note-draft-12345678-1234-1234-1234-123456789abc.m4a'
  self.assertEqual(capture_kind({'name':name,'properties':{'captureKind':'note_interrupted'}}),'note_interrupted')
