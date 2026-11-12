import Foundation
import Testing
@testable import AetherEngine

/// Fork (bettertv): `LoadOptions.liveMaxPlaylistSegments`, the session's own ceiling on how many
/// entries a native live playlist lists (AE#443's 900 by default). On `.fastZap` a segment is one GOP,
/// so 900 entries held a broadcast channel to about 15 minutes of timeshift whatever the disk budget
/// allowed. Unset, every number below is the one upstream 7.58.0 produces.
@Suite("Live max playlist segments", .timeLimit(.minutes(3)))
struct LiveMaxPlaylistSegmentsTests {

    private func makeProvider(dvrWindowSeconds: Double, ceiling: Int,
                              policy: LiveDVRRetentionPolicy? = nil) -> (VideoSegmentProvider, SegmentCache) {
        let cache = SegmentCache(forwardWindow: 32, backwardWindow: 32, nativeLiveDVRPolicy: policy)
        let provider = VideoSegmentProvider(
            cache: cache, segments: [], codecsString: "avc1.64002A", supplementalCodecs: nil,
            resolution: (1920, 1080), videoRange: .sdr, frameRate: 25, hdcpLevel: nil,
            sourceBitrate: 4_000_000, isLive: true,
            liveWindowSizing: LiveWindowSizing(targetSegmentDurationSeconds: 0.5,
                                               dvrWindowSeconds: dvrWindowSeconds,
                                               playlistCeilingSegments: ceiling),
            nativeLiveDVRPolicy: policy)
        return (provider, cache)
    }

    /// Uniform 1 s segments, the broadcast `.fastZap` shape the field log came from.
    private func appendOneSecondSegments(_ provider: VideoSegmentProvider, count: Int, from first: Int = 0) {
        for index in first..<(first + count) {
            provider.appendLiveSegment(index: index, startSeconds: Double(index), durationSeconds: 1)
        }
    }

    private func entries(_ playlist: String) -> Int {
        playlist.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }.count
    }

    // MARK: - Resolution

    @Test("unset, zero or negative keeps the automatic 900", arguments: [Int?.none, 0, -1, Int.min])
    func unsetKeepsDefault(requested: Int?) {
        #expect(LiveWindowSizing.resolvedMaxPlaylistSegments(requested) == 900)
        #expect(LiveWindowSizing.resolvedMaxPlaylistSegments(requested) == LiveWindowSizing.maxWindowSegments)
    }

    @Test("a ceiling below minSafeSegments is raised to it")
    func belowFloorIsRaised() {
        #expect(LiveWindowSizing.resolvedMaxPlaylistSegments(1) == LiveWindowSizing.minSafeSegments)
        #expect(LiveWindowSizing.resolvedMaxPlaylistSegments(7) == LiveWindowSizing.minSafeSegments)
        #expect(LiveWindowSizing.resolvedMaxPlaylistSegments(8) == 8)
        #expect(LiveWindowSizing.resolvedMaxPlaylistSegments(300) == 300)
    }

    @Test("a ceiling above the upper bound is clamped to it")
    func aboveMaxIsClamped() {
        #expect(LiveWindowSizing.resolvedMaxPlaylistSegments(5400) == 5400)
        #expect(LiveWindowSizing.resolvedMaxPlaylistSegments(21_600) == 21_600)
        #expect(LiveWindowSizing.resolvedMaxPlaylistSegments(21_601) == LiveWindowSizing.maxPlaylistSegmentsUpperBound)
        #expect(LiveWindowSizing.resolvedMaxPlaylistSegments(Int.max) == LiveWindowSizing.maxPlaylistSegmentsUpperBound)
    }

    // MARK: - Sizing

    @Test("a sizing built without a ceiling is the upstream one")
    func sizingDefaultIsUpstream() {
        let sizing = LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: 5400)
        #expect(sizing.playlistCeilingSegments == 900)
        #expect(sizing.windowSegmentCount(observedSegmentDurationSeconds: 1.0) == 900)
    }

    @Test("a 5400 ceiling lets a 5400 s window at a 1 s cadence through")
    func raisedCeilingLetsTheWindowThrough() {
        let sizing = LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: 5400,
                                      playlistCeilingSegments: 5400)
        #expect(sizing.windowSegmentCount(observedSegmentDurationSeconds: 1.0) == 5400)
        // The ceiling is a bound, not a target: a shorter window keeps its own depth.
        let shorter = LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: 1800,
                                       playlistCeilingSegments: 5400)
        #expect(shorter.windowSegmentCount(observedSegmentDurationSeconds: 1.0) == 1800)
        // And a deeper window stops at it.
        let deeper = LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: 7200,
                                      playlistCeilingSegments: 5400)
        #expect(deeper.windowSegmentCount(observedSegmentDurationSeconds: 1.0) == 5400)
    }

    @Test("the byte budget still bounds the window when it is the smaller limit")
    func byteBudgetStillBinds() {
        // 2 GiB of 1 MiB segments is 2048 entries, under the 5400 the ceiling allows.
        let sizing = LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: 5400,
                                      retentionBudgetBytes: 2 << 30, playlistCeilingSegments: 5400)
        #expect(sizing.windowSegmentCount(observedSegmentDurationSeconds: 1.0,
                                          observedSegmentBytes: 1 << 20) == 2048)
        // minSafeSegments still floors a starved budget.
        let starved = LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: 5400,
                                       retentionBudgetBytes: 1 << 20, playlistCeilingSegments: 5400)
        #expect(starved.windowSegmentCount(observedSegmentDurationSeconds: 1.0,
                                           observedSegmentBytes: 1 << 20) == LiveWindowSizing.minSafeSegments)
    }

    // MARK: - Provider

    @Test("the served playlist lists the raised window, and 900 entries when unset")
    func servedPlaylistFollowsTheCeiling() {
        let (raised, raisedCache) = makeProvider(dvrWindowSeconds: 5400, ceiling: 5400)
        defer { raisedCache.close() }
        appendOneSecondSegments(raised, count: 6000)
        let deep = HLSLocalServer.buildMediaPlaylistText(provider: raised)
        #expect(entries(deep) == 5400)
        #expect(deep.contains("#EXT-X-MEDIA-SEQUENCE:600\n"))

        let (upstream, upstreamCache) = makeProvider(dvrWindowSeconds: 5400, ceiling: LiveWindowSizing.maxWindowSegments)
        defer { upstreamCache.close() }
        appendOneSecondSegments(upstream, count: 6000)
        let capped = HLSLocalServer.buildMediaPlaylistText(provider: upstream)
        #expect(entries(capped) == 900)
        #expect(capped.contains("#EXT-X-MEDIA-SEQUENCE:5100\n"))
    }

    @Test("the resident park cap follows the raised window")
    func residentParkCapFollows() {
        let slack = VideoSegmentProvider.liveResidentParkSlackSegments
        let (raised, raisedCache) = makeProvider(dvrWindowSeconds: 5400, ceiling: 5400)
        defer { raisedCache.close() }
        appendOneSecondSegments(raised, count: 20)
        #expect(raised.liveResidentParkCap() == 5400 + slack)

        let (upstream, upstreamCache) = makeProvider(dvrWindowSeconds: 5400, ceiling: LiveWindowSizing.maxWindowSegments)
        defer { upstreamCache.close() }
        appendOneSecondSegments(upstream, count: 20)
        #expect(upstream.liveResidentParkCap() == 900 + slack)
    }

    @Test("a native DVR lease keeps the session's ceiling")
    func nativeLeaseKeepsTheCeiling() {
        let policy = LiveDVRRetentionPolicy(now: { 0 })
        policy.update(LiveDVRLimits(windowSeconds: 5400, maximumBytes: 64 << 30,
                                    minimumFreeBytes: 128 << 20, capacityValidUntil: 3),
                      availableBytes: 256 << 30, residentBytes: 0)
        #expect(policy.snapshot?.windowSeconds == 5400)
        let slack = VideoSegmentProvider.liveResidentParkSlackSegments
        let (raised, raisedCache) = makeProvider(dvrWindowSeconds: 60, ceiling: 5400, policy: policy)
        defer { raisedCache.close() }
        appendOneSecondSegments(raised, count: 20)
        // The lease's 5400 s window replaces the base 60 s one; the rebuilt sizing must still carry
        // the 5400 ceiling or this would read 900 + slack.
        #expect(raised.liveResidentParkCap() == 5400 + slack)

        let (upstream, upstreamCache) = makeProvider(dvrWindowSeconds: 60, ceiling: LiveWindowSizing.maxWindowSegments,
                                                     policy: policy)
        defer { upstreamCache.close() }
        appendOneSecondSegments(upstream, count: 20)
        #expect(upstream.liveResidentParkCap() == 900 + slack)
    }

    @Test("the #443 clamp line names the session's ceiling")
    func clampLogNamesTheCeiling() {
        let capture = EngineLogCapture()
        defer { capture.end() }
        // 7123 s is this test's marker: no other test asks for it.
        let (provider, cache) = makeProvider(dvrWindowSeconds: 7123, ceiling: 5400)
        defer { cache.close() }
        appendOneSecondSegments(provider, count: 20)
        _ = provider.notePlaylistBuild()
        let lines = capture.matching("of the 7123 asked for")
        #expect(lines.count == 1)
        #expect(lines.first?.contains("served at 5400 segments") == true)
        #expect(lines.first?.contains("capped at 5400 entries") == true)
    }

    // MARK: - Cost

    /// The per-poll cost the ceiling buys, for a host deciding whether its slowest device can afford a
    /// deeper playlist. Off by default (it times, it does not judge): `AETHER_PLAYLIST_BENCH=1`. Prints
    /// the median of repeated builds of a full window of 1 s segments, the bytes one poll serves, and
    /// the resident-floor walk `seekableLiveRange` runs on its tick.
    @Test("playlist build cost by window depth",
          .enabled(if: ProcessInfo.processInfo.environment["AETHER_PLAYLIST_BENCH"] != nil))
    func playlistBuildCost() {
        func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }
        func millis(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        for depth in [900, 5400, 21_600] {
            let (provider, cache) = makeProvider(dvrWindowSeconds: Double(depth), ceiling: depth)
            defer { cache.close() }
            appendOneSecondSegments(provider, count: depth)
            for index in 0..<depth { _ = cache.store(index: index, data: Data(repeating: 1, count: 16)) }
            let first = HLSLocalServer.buildMediaPlaylistText(provider: provider)
            #expect(entries(first) == depth)
            let rounds = depth > 5400 ? 15 : 41
            let build = median((0..<rounds).map { _ in
                millis { _ = HLSLocalServer.buildMediaPlaylistText(provider: provider) } })
            let floorWalk = median((0..<rounds).map { _ in
                millis { _ = provider.residentFloorOutputSeconds() } })
            #expect(provider.residentFloorOutputSeconds() == 0)
            print("[bench] liveMaxPlaylistSegments depth=\(depth) build_median_ms="
                  + String(format: "%.3f", build) + " bytes=\(first.utf8.count) floor_walk_median_ms="
                  + String(format: "%.3f", floorWalk))
        }
    }

    // MARK: - Wiring

    @Test("the session init resolves the option for the window sizing")
    func sessionInitWiring() {
        let url = URL(string: "https://example.invalid/live")!
        #expect(HLSVideoEngine(url: url, isLiveSession: true).livePlaylistCeilingSegments == 900)
        #expect(HLSVideoEngine(url: url, isLiveSession: true,
                               liveMaxPlaylistSegments: 5400).livePlaylistCeilingSegments == 5400)
        #expect(HLSVideoEngine(url: url, isLiveSession: true,
                               liveMaxPlaylistSegments: 0).livePlaylistCeilingSegments == 900)
        #expect(HLSVideoEngine(url: url, isLiveSession: true,
                               liveMaxPlaylistSegments: .max).livePlaylistCeilingSegments == 21_600)
    }

    @Test("LoadOptions leaves the ceiling unset by default and treats it as a tuning field")
    func loadOptionsDefault() {
        #expect(LoadOptions().liveMaxPlaylistSegments == nil)
        var options = LoadOptions(isLive: true, dvrWindowSeconds: 5400)
        options.liveMaxPlaylistSegments = 5400
        #expect(options.liveMaxPlaylistSegments == 5400)
        #expect(SessionOptionCorrection.knownFields.contains("liveMaxPlaylistSegments"))
        #expect(!SessionOptionCorrection.loadIdentityFields.contains("liveMaxPlaylistSegments"))
    }
}
