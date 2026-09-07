import XCTest
@testable import Pills

/// Covers the DTO → SwiftData model mapping and JSON config parsing that the
/// app relies on for offline caching and rendering guide content.
final class PersistenceModelTests: XCTestCase {

    // MARK: - Guide config parsing

    private func makeGuideDTO(
        config: GuideConfig,
        slug: String = "4-7-8-breathing",
        title: String = "4-7-8 呼吸法"
    ) -> GuideDTO {
        GuideDTO(
            id: "g1",
            slug: slug,
            title: title,
            description: "描述",
            category: "breathing",
            sort_order: 1,
            active: true,
            config: config
        )
    }

    func testGuideInitFromDTO_mapsAllScalarFields() {
        let dto = makeGuideDTO(config: GuideConfig(phases: nil, steps: nil))

        let guide = Guide(from: dto)

        XCTAssertEqual(guide.id, "g1")
        XCTAssertEqual(guide.slug, "4-7-8-breathing")
        XCTAssertEqual(guide.category, "breathing")
        XCTAssertEqual(guide.title, "4-7-8 呼吸法")
        XCTAssertEqual(guide.summary, "描述")
        XCTAssertEqual(guide.sortOrder, 1)
        XCTAssertTrue(guide.isActive)
    }

    func testGuidePhases_decodesBreathPhasesFromConfigJSON() {
        let phases = [
            GuideConfig.BreathPhase(name: "吸气", duration: 4),
            GuideConfig.BreathPhase(name: "闭气", duration: 7),
            GuideConfig.BreathPhase(name: "呼气", duration: 8)
        ]
        let guide = Guide(from: makeGuideDTO(config: GuideConfig(phases: phases, steps: nil)))

        let decoded = guide.phases
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded.map(\.name), ["吸气", "闭气", "呼气"])
        XCTAssertEqual(decoded.map(\.duration), [4, 7, 8])
    }

    func testGuideEstimatedDuration_sumsPhaseDurations() {
        let phases = [
            GuideConfig.BreathPhase(name: "吸气", duration: 4),
            GuideConfig.BreathPhase(name: "闭气", duration: 7),
            GuideConfig.BreathPhase(name: "呼气", duration: 8)
        ]
        let guide = Guide(from: makeGuideDTO(config: GuideConfig(phases: phases, steps: nil)))

        XCTAssertEqual(guide.estimatedDuration, 19)
    }

    func testGuidePhases_returnsEmptyForMalformedConfigJSON() {
        let guide = Guide(
            id: "g1", slug: "s", category: "breathing", title: "t",
            summary: "d", sortOrder: 1, isActive: true,
            configJSON: "{ this is not valid json"
        )

        XCTAssertTrue(guide.phases.isEmpty)
        XCTAssertEqual(guide.estimatedDuration, 0)
    }

    func testGuidePhases_returnsEmptyWhenConfigHasNoPhases() {
        // A body-scan style guide carries steps, not breathing phases.
        let steps = [GuideConfig.GuideStep(
            sense: nil, count: nil, prompt: "放松", body_part: "肩",
            tense_duration: 5, relax_duration: 10, tense_prompt: nil, relax_prompt: nil
        )]
        let guide = Guide(from: makeGuideDTO(config: GuideConfig(phases: nil, steps: steps)))

        XCTAssertTrue(guide.phases.isEmpty)
        XCTAssertEqual(guide.estimatedDuration, 0)
    }

    // MARK: - Session DTO mapping

    func testSessionInitFromDTO_parsesFractionalSecondTimestamps() {
        let dto = SessionDTO(
            id: "s1",
            guide_slug: "4-7-8-breathing",
            started_at: "2026-01-02T03:04:05.678Z",
            completed_at: "2026-01-02T03:05:05.678Z",
            duration_seconds: 60
        )

        let session = Session(from: dto)

        XCTAssertEqual(session.id, "s1")
        XCTAssertEqual(session.guideSlug, "4-7-8-breathing")
        XCTAssertEqual(session.durationSeconds, 60)
        XCTAssertNotNil(session.completedAt)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: session.startedAt)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 1)
        XCTAssertEqual(comps.day, 2)
        XCTAssertEqual(comps.hour, 3)
    }

    func testSessionInitFromDTO_parsesWholeSecondTimestampsViaFallback() throws {
        let dto = SessionDTO(
            id: "s1",
            guide_slug: "g",
            started_at: "2026-01-02T03:04:05Z",
            completed_at: "2026-01-02T03:05:06Z",
            duration_seconds: 61
        )

        let session = Session(from: dto)

        XCTAssertEqual(session.durationSeconds, 61)

        // The primary formatter requires fractional seconds, so a whole-second
        // timestamp must be resolved by the fallback formatter. Assert the exact
        // wall-clock value to prove it parsed rather than falling through to
        // `?? Date()` (which would also be > 0 and mask a parse failure).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let started = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: session.startedAt)
        XCTAssertEqual(started.year, 2026)
        XCTAssertEqual(started.month, 1)
        XCTAssertEqual(started.day, 2)
        XCTAssertEqual(started.hour, 3)
        XCTAssertEqual(started.minute, 4)
        XCTAssertEqual(started.second, 5)

        let completed = try XCTUnwrap(session.completedAt)
        let completedComps = calendar.dateComponents([.hour, .minute, .second], from: completed)
        XCTAssertEqual(completedComps.hour, 3)
        XCTAssertEqual(completedComps.minute, 5)
        XCTAssertEqual(completedComps.second, 6)
    }

    func testSessionApply_refreshesCompletionFieldsInPlace() {
        let session = Session(id: "s1", guideSlug: "g", startedAt: Date(timeIntervalSince1970: 0))
        XCTAssertNil(session.completedAt)

        let dto = SessionDTO(
            id: "s1",
            guide_slug: "renamed-guide",
            started_at: "2026-01-02T03:04:05.678Z",
            completed_at: "2026-01-02T03:05:05.678Z",
            duration_seconds: 120
        )
        session.apply(dto)

        XCTAssertEqual(session.guideSlug, "renamed-guide")
        XCTAssertEqual(session.durationSeconds, 120)
        XCTAssertNotNil(session.completedAt)
    }

    func testSessionApply_keepsStartedAtWhenTimestampUnparseable() {
        let original = Date(timeIntervalSince1970: 1_000)
        let session = Session(id: "s1", guideSlug: "g", startedAt: original)

        let dto = SessionDTO(
            id: "s1",
            guide_slug: "g",
            started_at: "not-a-date",
            completed_at: nil,
            duration_seconds: nil
        )
        session.apply(dto)

        XCTAssertEqual(session.startedAt, original, "Unparseable started_at must not clobber the cached value")
    }
}
