package org.example.captura;
import org.junit.Test;
import static org.junit.Assert.*;
public class NoteSessionTest {
 @Test public void restoresRecordingAndDoesNotResetDeadline() {
  NoteSession n = new NoteSession(); assertTrue(n.begin(true,100));
  assertFalse(n.begin(false,1000)); assertFalse(n.expired(60099)); assertTrue(n.expired(60100));
  assertTrue(n.finish()); assertFalse(n.active()); assertFalse(n.finish());
 }
 @Test public void listeningReturnsToListening() {
  NoteSession n = new NoteSession(); assertTrue(n.begin(false,100)); assertFalse(n.finish());
  assertTrue(n.begin(true,200)); assertTrue(n.finish());
 }
 @Test public void captureKindsAreBounded() {
  String id="12345678-1234-1234-1234-123456789abc";
  assertEquals("dictated_note",CaptureKind.fromName("personal-capture-note-"+id+".m4a"));
  assertEquals("note_interrupted",CaptureKind.fromName("personal-capture-note-draft-"+id+".m4a"));
  assertEquals("ambient_audio",CaptureKind.fromName("personal-capture-note-hello.m4a"));
 }
}
