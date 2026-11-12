import Testing
@testable import AetherEngine

/// Fork (bettertv): `BetterTVFork.diskReserveBytes`. Only the pure form is exercised here: the
/// process-wide value is shared with every other suite that sizes a budget, and they run in parallel.
@Suite("Disk reserve")
struct DiskReserveTests {
    private let gib: Int64 = 1 << 30

    @Test("without a reserve the limit is a quarter of the free space, as upstream")
    func noReserveIsQuarter() {
        #expect(BetterTVFork.volumeSafetyLimit(availableBytes: 8 * gib, reserve: nil) == 2 * gib)
        #expect(BetterTVFork.volumeSafetyLimit(availableBytes: 0, reserve: nil) == 0)
    }

    @Test("with a reserve the limit is the free space above it")
    func reserveLeavesOneGiB() {
        // A full Apple TV 4K: 2.6 GB free held 650 MB under the quarter, about 1.6 GB with the reserve.
        let available = Int64(2_650) << 20
        #expect(BetterTVFork.volumeSafetyLimit(availableBytes: available, reserve: gib) == available - gib)
        #expect(BetterTVFork.volumeSafetyLimit(availableBytes: 64 * gib, reserve: gib) == 63 * gib)
    }

    @Test("a reserve never gives less than the quarter")
    func neverBelowQuarter() {
        let available = Int64(1_200) << 20
        #expect(BetterTVFork.volumeSafetyLimit(availableBytes: available, reserve: gib) == available / 4)
        #expect(BetterTVFork.volumeSafetyLimit(availableBytes: gib / 2, reserve: gib) == gib / 8)
    }
}
