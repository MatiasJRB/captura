package org.example.captura;
final class CaptureKind {
    static String fromName(String name) {
        if (name != null && name.matches("personal-capture-note-draft-[a-f0-9-]{36}\\.m4a")) return "note_interrupted";
        if (name != null && name.matches("personal-capture-note-[a-f0-9-]{36}\\.m4a")) return "dictated_note";
        return "ambient_audio";
    }
}
