package org.example.captura;

/** No cellular fallback for automatic transfers. A manual request has a bounded lifetime. */
public final class SyncPolicy {
    public static final long MANUAL_WINDOW_MS = 30L * 60L * 1000L;
    public static boolean allowed(boolean manual, boolean wifi, boolean online, long requestedAt, long now) {
        return online && (manual ? now >= requestedAt && now - requestedAt <= MANUAL_WINDOW_MS : wifi);
    }
    public static boolean verified(long localBytes, String localMd5, String localSha,
                                   long remoteBytes, String remoteMd5, String remoteSha, boolean correctParent) {
        return localBytes > 0 && localBytes == remoteBytes && correctParent
                && localMd5 != null && localMd5.equals(remoteMd5)
                && localSha != null && localSha.equals(remoteSha);
    }
}
