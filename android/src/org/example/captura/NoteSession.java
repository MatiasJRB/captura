package org.example.captura;
final class NoteSession {
    static final long LIMIT_MS = 60_000;
    private boolean active, resume;
    private long started;
    boolean begin(boolean recording, long now) {
        if (active) return false;
        active = true; resume = recording; started = now; return true;
    }
    boolean active() { return active; }
    boolean expired(long now) { return active && now - started >= LIMIT_MS; }
    boolean finish() { boolean previous = resume; active = false; resume = false; return previous; }
}
