import Foundation

/// Process-wide settings added by BetterTV's fork (branch `bettertv`). Set them once, before the first
/// load; they are read whenever a session sizes its disk budget.
public enum BetterTVFork {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _diskReserveBytes: Int64?

    /// Free space to leave on the cache volume. When set, a session's disk budget may use the free
    /// space minus this reserve instead of a quarter of it, and never less than the quarter, so a full
    /// device is no worse off than before. The quarter is right for a phone, where the cache competes
    /// with the person's own files; an Apple TV running a live pause has nothing else to keep free,
    /// and a quarter of the 2 to 3 GB a full one reports holds only about 13 minutes of 1080i H.264.
    /// The per-session request (`LoadOptions.liveDVRByteBudget`, `sessionCacheByteBudget`) and the
    /// 2 GiB default for an unset VOD budget still apply on top. nil (default) keeps the quarter.
    public static var diskReserveBytes: Int64? {
        get { lock.lock(); defer { lock.unlock() }; return _diskReserveBytes }
        set { lock.lock(); _diskReserveBytes = newValue.map { max(0, $0) }; lock.unlock() }
    }

    /// The most a session may take from `available` free bytes: a quarter of them, or with a reserve
    /// set, everything above the reserve when that is more.
    static func volumeSafetyLimit(availableBytes available: Int64) -> Int64 {
        volumeSafetyLimit(availableBytes: available, reserve: diskReserveBytes)
    }

    static func volumeSafetyLimit(availableBytes available: Int64, reserve: Int64?) -> Int64 {
        let quarter = max(0, available / 4)
        guard let reserve else { return quarter }
        return max(quarter, available - reserve)
    }
}
