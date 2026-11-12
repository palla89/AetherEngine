import Foundation
import Testing
@testable import AetherEngine

/// Fork (bettertv): `LoadOptions.liveDVRByteBudget`, the live counterpart of `sessionCacheByteBudget`.
/// It replaces the automatic 2 GiB default for live DVR history on both routes and keeps every other
/// bound: the quarter-of-free-space clamp, the 2 GiB ceiling for unknown capacity and the software
/// ring's 64 MiB floor. Unset, a live session sizes its history exactly as upstream 7.58.0 did.
@Suite("Live DVR byte budget", .timeLimit(.minutes(3)))
struct LiveDVRByteBudgetTests {

    // MARK: - Software ring

    @Test("unset, the software ring keeps the automatic 2 GiB budget",
          arguments: [Int64?.none, 0, 1 << 30, 4 << 30, 64 << 30])
    func softwareAutomaticIsUnchanged(available: Int64?) {
        let automatic = max(PacketRingBuffer.minimumLiveByteBudget,
                            HLSVideoEngine.sessionRetentionBudgetBytes(volumeAvailableBytes: available))
        #expect(PacketRingBuffer.liveByteBudget(volumeAvailableBytes: available) == automatic)
        #expect(PacketRingBuffer.liveByteBudget(volumeAvailableBytes: available, requestedBytes: nil) == automatic)
        #expect(PacketRingBuffer.liveByteBudget(volumeAvailableBytes: available, requestedBytes: 0) == automatic)
        #expect(PacketRingBuffer.liveByteBudget(volumeAvailableBytes: available, requestedBytes: -1) == automatic)
    }

    @Test("the default on a roomy volume is 2 GiB")
    func softwareDefaultIsTwoGiB() {
        #expect(PacketRingBuffer.liveByteBudget(volumeAvailableBytes: 64 << 30) == 2 << 30)
    }

    @Test("a larger request is honoured where the volume affords it")
    func softwareLargerRequestHonoured() {
        #expect(PacketRingBuffer.liveByteBudget(volumeAvailableBytes: 64 << 30,
                                                requestedBytes: 8 << 30) == 8 << 30)
    }

    @Test("a smaller request is honoured above the floor")
    func softwareSmallerRequestHonoured() {
        #expect(PacketRingBuffer.liveByteBudget(volumeAvailableBytes: 64 << 30,
                                                requestedBytes: 512 << 20) == 512 << 20)
    }

    @Test("the quarter-of-free-space clamp still applies to a request")
    func softwareQuarterClampApplies() {
        #expect(PacketRingBuffer.liveByteBudget(volumeAvailableBytes: 16 << 30,
                                                requestedBytes: 8 << 30) == 4 << 30)
    }

    @Test("unknown capacity keeps the 2 GiB ceiling even for a larger request")
    func softwareUnknownCapacityKeepsCeiling() {
        #expect(PacketRingBuffer.liveByteBudget(volumeAvailableBytes: nil,
                                                requestedBytes: 8 << 30) == 2 << 30)
    }

    @Test("the 64 MiB playback floor survives both a tiny request and a full volume")
    func softwareFloorSurvives() {
        let floor = PacketRingBuffer.minimumLiveByteBudget
        #expect(PacketRingBuffer.liveByteBudget(volumeAvailableBytes: 64 << 30, requestedBytes: 1 << 20) == floor)
        #expect(PacketRingBuffer.liveByteBudget(volumeAvailableBytes: 100 << 20, requestedBytes: 8 << 30) == floor)
    }

    @Test("the claim ledger hands the request out of the space other sessions left")
    func softwareRequestSharesTheLedger() {
        let ledger = RetentionClaims()
        let other = ledger.claim(volumeAvailableBytes: 40 << 30) { _ in 8 << 30 }
        defer { other.release() }
        // 32 GiB left after the other session's unwritten 8 GiB: a quarter is 8 GiB.
        let ring = ledger.claim(volumeAvailableBytes: 40 << 30) {
            PacketRingBuffer.liveByteBudget(volumeAvailableBytes: $0, requestedBytes: 12 << 30)
        }
        defer { ring.release() }
        #expect(ring.bytes == 8 << 30)
    }

    /// The request reaches the DVR ring. 80 MiB sits between the 64 MiB floor and the 2 GiB default,
    /// so without the request the ring would size to 2 GiB on any roomy volume. The ring sizes against
    /// the real volume and the shared claims ledger, which concurrent tests also hold, so a crowded
    /// disk may push it down to the floor; it can never exceed the request.
    @MainActor
    @Test("prepareLiveDVR sizes the ring by the requested budget")
    func hostRingUsesRequest() throws {
        let host = SoftwarePlaybackHost()
        defer { host.stop() }
        let ring = try #require(host.prepareLiveDVR(windowSeconds: 3600, requestedBytes: 80 << 20))
        #expect(ring.byteBudget <= 80 << 20)
        #expect(ring.byteBudget >= PacketRingBuffer.minimumLiveByteBudget)
    }

    // MARK: - Native loopback

    @Test("a live session resolves against the live budget, a VOD session against the VOD one")
    func nativeRequestSelection() {
        // Unset on live: automatic, even when the host set a VOD budget for every load.
        #expect(HLSVideoEngine.retentionRequestBytes(isLive: true, sessionCacheByteBudget: 123,
                                                     liveDVRByteBudget: nil) == nil)
        #expect(HLSVideoEngine.retentionRequestBytes(isLive: true, sessionCacheByteBudget: nil,
                                                     liveDVRByteBudget: 0) == nil)
        #expect(HLSVideoEngine.retentionRequestBytes(isLive: true, sessionCacheByteBudget: nil,
                                                     liveDVRByteBudget: -5) == nil)
        #expect(HLSVideoEngine.retentionRequestBytes(isLive: true, sessionCacheByteBudget: 123,
                                                     liveDVRByteBudget: 8 << 30) == 8 << 30)
        // VOD never reads the live budget.
        #expect(HLSVideoEngine.retentionRequestBytes(isLive: false, sessionCacheByteBudget: 123,
                                                     liveDVRByteBudget: 8 << 30) == 123)
        #expect(HLSVideoEngine.retentionRequestBytes(isLive: false, sessionCacheByteBudget: nil,
                                                     liveDVRByteBudget: 8 << 30) == nil)
    }

    @Test("the session init carries the live budget into the retention request")
    func nativeSessionWiring() {
        let url = URL(string: "https://example.invalid/live")!
        let unset = HLSVideoEngine(url: url, isLiveSession: true, sessionCacheByteBudget: 123)
        #expect(unset.retentionRequestBytes == nil)
        let live = HLSVideoEngine(url: url, isLiveSession: true, sessionCacheByteBudget: 123,
                                  liveDVRByteBudget: 8 << 30)
        #expect(live.retentionRequestBytes == 8 << 30)
        let vod = HLSVideoEngine(url: url, isLiveSession: false, sessionCacheByteBudget: 123,
                                 liveDVRByteBudget: 8 << 30)
        #expect(vod.retentionRequestBytes == 123)
    }

    @Test("native live retention: 2 GiB default, larger request honoured, quarter clamp kept")
    func nativeResolution() {
        func live(_ request: Int?, _ available: Int64?) -> Int {
            HLSVideoEngine.resolveSessionCacheBudget(
                requestedBytes: HLSVideoEngine.retentionRequestBytes(
                    isLive: true, sessionCacheByteBudget: nil, liveDVRByteBudget: request),
                volumeAvailableBytes: available).enforcedBytes(isLive: true)
        }
        #expect(live(nil, 64 << 30) == 2 << 30)
        #expect(live(nil, 64 << 30) == HLSVideoEngine.sessionRetentionBudgetBytes(volumeAvailableBytes: 64 << 30))
        #expect(live(8 << 30, 64 << 30) == 8 << 30)
        #expect(live(8 << 30, 16 << 30) == 4 << 30)
        #expect(live(8 << 30, nil) == 2 << 30)
        #expect(live(512 << 20, 64 << 30) == 512 << 20)
    }

    @Test("a live request the volume clamps to zero stays the automatic zero, not a 1 byte bound")
    func nativeClampedToZeroStaysAutomatic() {
        let starved = HLSVideoEngine.resolveSessionCacheBudget(requestedBytes: 8 << 30, volumeAvailableBytes: 3)
        #expect(starved.enforcedBytes(isLive: true) == 0)
        #expect(starved.enforcedBytes(isLive: false) == starved.enforcedBytes)
        #expect(starved.enforcedBytes == 1)
        let automatic = HLSVideoEngine.resolveSessionCacheBudget(requestedBytes: nil, volumeAvailableBytes: 3)
        #expect(automatic.enforcedBytes(isLive: true) == automatic.enforcedBytes)
    }

    // MARK: - LoadOptions

    @Test("LoadOptions leaves the live budget unset by default")
    func loadOptionsDefault() {
        #expect(LoadOptions().liveDVRByteBudget == nil)
        var options = LoadOptions(isLive: true, dvrWindowSeconds: 3600)
        options.liveDVRByteBudget = 8 << 30
        #expect(options.liveDVRByteBudget == 8 << 30)
        #expect(SessionOptionCorrection.knownFields.contains("liveDVRByteBudget"))
        #expect(!SessionOptionCorrection.loadIdentityFields.contains("liveDVRByteBudget"))
    }
}
