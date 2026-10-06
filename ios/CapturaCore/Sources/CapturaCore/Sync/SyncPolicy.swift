import Foundation

/// Port of `SyncPolicy.java`.
///
/// Automatic transfers never fall back to cellular. A manual request may use any
/// validated network, but only for a bounded window after the person asked for it.
public enum SyncPolicy {
    /// `SyncPolicy.MANUAL_WINDOW_MS`: 30 minutes.
    public static let manualWindow: TimeInterval = 30 * 60

    public static func allowed(manual: Bool, wifi: Bool, online: Bool, requestedAt: Date, now: Date) -> Bool {
        guard online else { return false }
        if manual {
            return now >= requestedAt && now.timeIntervalSince(requestedAt) <= manualWindow
        }
        return wifi
    }

    /// A remote copy counts as uploaded only with every piece of evidence: same
    /// non-zero size, Drive MD5, our SHA-256 property and the expected parent folder.
    public static func verified(
        localBytes: Int64, localMD5: String?, localSHA: String?,
        remoteBytes: Int64, remoteMD5: String?, remoteSHA: String?,
        correctParent: Bool
    ) -> Bool {
        guard localBytes > 0, localBytes == remoteBytes, correctParent else { return false }
        guard let localMD5, localMD5 == remoteMD5 else { return false }
        guard let localSHA, localSHA == remoteSHA else { return false }
        return true
    }
}
