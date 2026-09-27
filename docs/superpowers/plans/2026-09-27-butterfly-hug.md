# Butterfly Hug (蝴蝶拥抱) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a butterfly hug grounding exercise — a backend-seeded guide with a dedicated iOS view that guides alternating left/right taps (visual wings + per-beat haptics), free-form start/stop, recorded through the existing session pipeline.

**Architecture:** The guide is data-driven from the backend `guides` table (category `grounding`, config `mode = bilateral_tap`). iOS widens the Home fetch/predicate to include `grounding`, filters to renderable guides, and routes butterfly guides to a new `ButterflyHugView` driven by a new `ButterflyHugViewModel`. The view model mirrors `BreathingViewModel`'s proven session lifecycle (generation guards, `canStart`, background/dismiss auto-stop, idempotency key, offline completion queue) but replaces the breath-phase machine with an alternating-tap metronome loop.

**Tech Stack:** Swift 6 / SwiftUI / SwiftData / Observation (iOS); FastAPI / aiosqlite / pytest (backend); XcodeGen for project generation; edge-tts is NOT used here.

## Global Constraints

- Timezone for any timestamps in commands: Asia/Taipei (UTC+08:00); dates use `YYYY-MM-DD`.
- iOS: portrait-only, Chinese (zh-Hans) user-facing copy, Dynamic Type + VoiceOver labels consistent with existing views.
- iOS: after adding ANY new `.swift` file, run `xcodegen generate` before building/testing (folder-based sources; also regenerates `Info.plist` from `project.yml`).
- Xcode test command (single test class):
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pills.xcodeproj -scheme Pills -destination 'platform=iOS Simulator,id=84F70310-5F7E-4DC7-97BB-5CDD020E811F' -only-testing:PillsTests/<ClassName> test`
  Run from `/Users/ben/projects/PillsIOS`.
- Backend test command: `cd /Users/ben/projects/PillsEC2 && ~/projects/PillsEC2/.venv/bin/python -m pytest <path> -v`
- Do NOT modify `BreathingViewModel`'s behavior. Per the approved Approach A, `ButterflyHugViewModel` carries its own private copy of the pending-completion queue helpers; this duplication is accepted to avoid touching just-shipped, approved breathing code.
- The butterfly `mode` flag — NOT the `grounding` category — decides routing, because the existing `grounding-54321` guide is steps-based and must not open the butterfly view.
- Never commit or push unless the user explicitly asks. Each task's final "Commit" step is to be run only when the user has authorized committing (the plan includes commit steps as the standard TDD cadence; confirm before the first one).

---

### Task 1: Backend seed + migration 005 for the butterfly hug guide

**Files:**
- Modify: `/Users/ben/projects/PillsEC2/backend/seeds/guides.json` (append one object to the top-level array)
- Modify: `/Users/ben/projects/PillsEC2/backend/db.py` (add migration version constant near line 18; add migration block before `await db.commit()` at line 248)
- Test: `/Users/ben/projects/PillsEC2/backend/tests/test_migrations.py` (add two tests)

**Interfaces:**
- Consumes: existing `_run_migrations(db)` / `init_db()` flow, `schema_migrations` table, `guides` table (columns: `id, slug, title, description, category, config, sort_order, active, created_at`).
- Produces: a `guides` row with `slug = "grounding-butterfly-hug"`, `category = "grounding"`, `config` JSON containing `"mode": "bilateral_tap"`, `"tap_interval": 1.0`, `"default_duration": 60`, `"min_duration": 15`, `active = 1`, `sort_order = 9`. Migration version string `"005_butterfly_hug_guide"`.

- [ ] **Step 1: Write the failing tests**

Append to `/Users/ben/projects/PillsEC2/backend/tests/test_migrations.py`:

```python
@pytest.mark.asyncio
async def test_butterfly_hug_migration_adds_guide_to_populated_database(tmp_path, monkeypatch):
    """A DB that already has guides (prod case) still gets butterfly hug via migration 005."""
    path = tmp_path / "populated.db"
    _create_legacy_database(path)
    monkeypatch.setattr(db_module, "_DB_PATH", str(path))

    # First init runs the empty-table seed load (legacy DB has no guides yet -> seeds all).
    await db_module.init_db()

    # Simulate a prod DB that was seeded BEFORE butterfly hug existed: drop the row
    # and its migration marker, then re-run to prove the migration re-adds it.
    db = sqlite3.connect(path)
    db.execute("DELETE FROM guides WHERE slug = 'grounding-butterfly-hug'")
    db.execute("DELETE FROM schema_migrations WHERE version = '005_butterfly_hug_guide'")
    db.commit()
    db.close()

    await db_module.init_db()

    db = sqlite3.connect(path)
    row = db.execute(
        "SELECT category, config, sort_order, active FROM guides WHERE slug = 'grounding-butterfly-hug'"
    ).fetchone()
    version_count = db.execute(
        "SELECT COUNT(*) FROM schema_migrations WHERE version = '005_butterfly_hug_guide'"
    ).fetchone()[0]
    db.close()

    assert row is not None
    category, config_json, sort_order, active = row
    assert category == "grounding"
    assert sort_order == 9
    assert active == 1
    config = json.loads(config_json)
    assert config["mode"] == "bilateral_tap"
    assert config["tap_interval"] == 1.0
    assert config["default_duration"] == 60
    assert config["min_duration"] == 15
    assert version_count == 1


@pytest.mark.asyncio
async def test_butterfly_hug_migration_is_idempotent(tmp_path, monkeypatch):
    path = tmp_path / "idem.db"
    _create_legacy_database(path)
    monkeypatch.setattr(db_module, "_DB_PATH", str(path))

    await db_module.init_db()
    await db_module.init_db()

    db = sqlite3.connect(path)
    count = db.execute(
        "SELECT COUNT(*) FROM guides WHERE slug = 'grounding-butterfly-hug'"
    ).fetchone()[0]
    versions = db.execute(
        "SELECT COUNT(*) FROM schema_migrations WHERE version = '005_butterfly_hug_guide'"
    ).fetchone()[0]
    db.close()

    assert count == 1
    assert versions == 1
```

Add `import json` to the imports at the top of `test_migrations.py` if not already present (it currently imports `asyncio`, `sqlite3`, `Path`, `pytest`, `backend.db as db_module`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/ben/projects/PillsEC2 && ~/projects/PillsEC2/.venv/bin/python -m pytest backend/tests/test_migrations.py -k butterfly -v`
Expected: FAIL — `test_butterfly_hug_migration_adds_guide_to_populated_database` asserts `row is not None` but gets `None` (guide/migration do not exist yet).

- [ ] **Step 3: Append the seed entry**

In `/Users/ben/projects/PillsEC2/backend/seeds/guides.json`, add this object as the last element of the top-level array (after the `mindfulness-10` entry, id `…0008`), keeping valid JSON (add a comma after the previous closing brace):

```json
  {
    "id": "a1b2c3d4-0009-4000-8000-000000000009",
    "slug": "grounding-butterfly-hug",
    "title": "蝴蝶拥抱",
    "description": "双臂交叉、双手轻放肩上，左右交替轻拍的自我安抚着陆练习，帮助快速平复情绪。",
    "category": "grounding",
    "config": {
      "mode": "bilateral_tap",
      "tap_interval": 1.0,
      "default_duration": 60,
      "min_duration": 15
    },
    "sort_order": 9,
    "active": true,
    "created_at": "2025-01-01T00:00:00Z"
  }
```

- [ ] **Step 4: Add the migration version constant**

In `/Users/ben/projects/PillsEC2/backend/db.py`, after line 18 (`_SESSION_IDEMPOTENCY_MIGRATION_VERSION = "004_session_idempotency_keys"`), add:

```python
_BUTTERFLY_HUG_MIGRATION_VERSION = "005_butterfly_hug_guide"
```

- [ ] **Step 5: Add the migration block**

In `_run_migrations`, immediately before the final `await db.commit()` (currently line 248, right after the `004` session-idempotency block that ends at line 247), insert:

```python
        cursor = await db.execute(
            "SELECT 1 FROM schema_migrations WHERE version = ?",
            (_BUTTERFLY_HUG_MIGRATION_VERSION,),
        )
        if not await cursor.fetchone():
            await db.execute(
                """INSERT OR IGNORE INTO guides
                   (id, slug, title, description, category, config, sort_order, active, created_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    "a1b2c3d4-0009-4000-8000-000000000009",
                    "grounding-butterfly-hug",
                    "蝴蝶拥抱",
                    "双臂交叉、双手轻放肩上，左右交替轻拍的自我安抚着陆练习，帮助快速平复情绪。",
                    "grounding",
                    json.dumps(
                        {
                            "mode": "bilateral_tap",
                            "tap_interval": 1.0,
                            "default_duration": 60,
                            "min_duration": 15,
                        },
                        ensure_ascii=False,
                    ),
                    9,
                    1,
                    "2025-01-01T00:00:00Z",
                ),
            )
            await db.execute(
                "INSERT INTO schema_migrations (version) VALUES (?)",
                (_BUTTERFLY_HUG_MIGRATION_VERSION,),
            )
```

`json` is already imported in `db.py` (used by `_load_seeds`). `INSERT OR IGNORE` dedups against the unique `slug`/`id` if the empty-table seed load already inserted the row.

- [ ] **Step 6: Run the migration tests to verify they pass**

Run: `cd /Users/ben/projects/PillsEC2 && ~/projects/PillsEC2/.venv/bin/python -m pytest backend/tests/test_migrations.py -v`
Expected: PASS — all tests including the two new butterfly tests.

- [ ] **Step 7: Add a route-level test that grounding filter returns the guide**

Append to `/Users/ben/projects/PillsEC2/backend/tests/test_config.py` (which already exercises `GET /api/guides` via the app's test client — match its existing fixture/client usage; if it uses a `client` fixture, reuse it):

```python
@pytest.mark.asyncio
async def test_guides_grounding_filter_includes_butterfly_hug(client):
    resp = await client.get("/api/guides", params={"category": "grounding"})
    assert resp.status_code == 200
    slugs = {g["slug"] for g in resp.json()["guides"]}
    assert "grounding-butterfly-hug" in slugs
    butterfly = next(g for g in resp.json()["guides"] if g["slug"] == "grounding-butterfly-hug")
    assert butterfly["category"] == "grounding"
    assert butterfly["config"]["mode"] == "bilateral_tap"
```

NOTE for the implementer: open `test_config.py` first and copy the exact client fixture name and call style it already uses for `/api/guides` (sync `client.get(...)` vs `await client.get(...)`, and the response envelope key). Adapt the test above to match — do not invent a new fixture. If `test_config.py` has no `/api/guides` test or no suitable client fixture, place this test in the file that does (grep `rg "/api/guides" backend/tests`).

- [ ] **Step 8: Run the backend suite**

Run: `cd /Users/ben/projects/PillsEC2 && ~/projects/PillsEC2/.venv/bin/python -m pytest backend/tests -v`
Expected: PASS (full suite green).

- [ ] **Step 9: Commit**

```bash
cd /Users/ben/projects/PillsEC2
git add backend/seeds/guides.json backend/db.py backend/tests/test_migrations.py backend/tests/test_config.py
git commit -m "Add butterfly hug grounding guide via seed and migration 005"
```

---

### Task 2: iOS GuideConfig + Guide accessors for butterfly hug

**Files:**
- Modify: `/Users/ben/projects/PillsIOS/Pills/Models/Guide.swift`
- Test: `/Users/ben/projects/PillsIOS/PillsTests/PersistenceModelTests.swift` (add a new test class or extend existing Guide tests)

**Interfaces:**
- Consumes: existing `GuideConfig: Codable` (fields `phases`, `steps`), `Guide` `@Model` with `configJSON: String`, existing `Guide.phases` accessor.
- Produces:
  - `GuideConfig` gains optional fields: `mode: String?`, `tap_interval: Double?`, `default_duration: Int?`, `min_duration: Int?`.
  - `struct ButterflyConfig: Equatable { let tapInterval: Double; let defaultDuration: Int; let minDuration: Int }`
  - `Guide.butterfly: ButterflyConfig?` (non-nil only when decoded `mode == "bilateral_tap"`).
  - `Guide.isButterflyHug: Bool`
  - `Guide.isRenderable: Bool` (true when `!phases.isEmpty || isButterflyHug`).

- [ ] **Step 1: Write the failing tests**

Add to `/Users/ben/projects/PillsIOS/PillsTests/PersistenceModelTests.swift`:

```swift
import XCTest
import SwiftData
@testable import Pills

final class ButterflyGuideConfigTests: XCTestCase {

    private func makeGuide(configJSON: String) -> Guide {
        Guide(
            id: UUID().uuidString,
            slug: "test-guide",
            category: "grounding",
            title: "Test",
            summary: "",
            sortOrder: 0,
            isActive: true,
            configJSON: configJSON
        )
    }

    func test_butterflyConfig_decodesFromBilateralTapMode() {
        let guide = makeGuide(configJSON:
            #"{"mode":"bilateral_tap","tap_interval":1.0,"default_duration":60,"min_duration":15}"#)
        let config = guide.butterfly
        XCTAssertEqual(config, ButterflyConfig(tapInterval: 1.0, defaultDuration: 60, minDuration: 15))
        XCTAssertTrue(guide.isButterflyHug)
        XCTAssertTrue(guide.isRenderable)
    }

    func test_butterflyConfig_appliesDefaultsWhenFieldsMissing() {
        let guide = makeGuide(configJSON: #"{"mode":"bilateral_tap"}"#)
        XCTAssertEqual(guide.butterfly, ButterflyConfig(tapInterval: 1.0, defaultDuration: 60, minDuration: 15))
    }

    func test_breathingGuide_isNotButterflyHug_butIsRenderable() {
        let guide = makeGuide(configJSON: #"{"phases":[{"name":"吸气","duration":4}]}"#)
        XCTAssertNil(guide.butterfly)
        XCTAssertFalse(guide.isButterflyHug)
        XCTAssertTrue(guide.isRenderable)
    }

    func test_stepsOnlyGuide_isNotRenderable() {
        let guide = makeGuide(configJSON:
            #"{"steps":[{"sense":"视觉","count":5,"prompt":"x"}]}"#)
        XCTAssertNil(guide.butterfly)
        XCTAssertFalse(guide.isButterflyHug)
        XCTAssertFalse(guide.isRenderable)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/ben/projects/PillsIOS && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pills.xcodeproj -scheme Pills -destination 'platform=iOS Simulator,id=84F70310-5F7E-4DC7-97BB-5CDD020E811F' -only-testing:PillsTests/ButterflyGuideConfigTests test`
Expected: FAIL to compile — `ButterflyConfig`, `guide.butterfly`, `isButterflyHug`, `isRenderable` are undefined.

- [ ] **Step 3: Extend GuideConfig and add accessors**

In `/Users/ben/projects/PillsIOS/Pills/Models/Guide.swift`, replace the `GuideConfig` struct with:

```swift
struct GuideConfig: Codable {
    let phases: [BreathPhase]?
    let steps: [GuideStep]?
    // Butterfly hug (bilateral tap) config. Additive + optional so existing
    // breathing/steps configs decode unchanged.
    let mode: String?
    let tap_interval: Double?
    let default_duration: Int?
    let min_duration: Int?

    struct BreathPhase: Codable {
        let name: String     // Chinese: "吸气", "闭气", "呼气"
        let duration: Double
    }

    struct GuideStep: Codable {
        let sense: String?
        let count: Int?
        let prompt: String?
        let body_part: String?
        let tense_duration: Double?
        let relax_duration: Double?
        let tense_prompt: String?
        let relax_prompt: String?
    }
}

/// Decoded, defaulted configuration for the butterfly hug exercise.
struct ButterflyConfig: Equatable {
    let tapInterval: Double
    let defaultDuration: Int
    let minDuration: Int
}
```

Then in the `extension Guide` block (which currently has `phases` and `estimatedDuration`), add:

```swift
    private var decodedConfig: GuideConfig? {
        guard let data = configJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GuideConfig.self, from: data)
    }

    /// Non-nil only for the bilateral-tap butterfly hug guide.
    var butterfly: ButterflyConfig? {
        guard let config = decodedConfig, config.mode == "bilateral_tap" else { return nil }
        return ButterflyConfig(
            tapInterval: config.tap_interval ?? 1.0,
            defaultDuration: config.default_duration ?? 60,
            minDuration: config.min_duration ?? 15
        )
    }

    var isButterflyHug: Bool { butterfly != nil }

    /// A guide the client can actually render: breathing phases OR butterfly hug.
    /// Steps-only guides (e.g. grounding-54321) are not yet renderable.
    var isRenderable: Bool { !phases.isEmpty || isButterflyHug }
```

Leave the existing `phases` and `estimatedDuration` members as-is. (Optional DRY cleanup: reimplement `phases` as `decodedConfig?.phases ?? []`; only do this if the existing `phases` body is otherwise unchanged, and confirm `BreathingViewModelTests` still pass.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/ben/projects/PillsIOS && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pills.xcodeproj -scheme Pills -destination 'platform=iOS Simulator,id=84F70310-5F7E-4DC7-97BB-5CDD020E811F' -only-testing:PillsTests/ButterflyGuideConfigTests test`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/ben/projects/PillsIOS
git add Pills/Models/Guide.swift PillsTests/PersistenceModelTests.swift
git commit -m "Decode butterfly hug config and add Guide render/routing accessors"
```

---

### Task 3: HapticPlayer protocol + impact implementation

**Files:**
- Create: `/Users/ben/projects/PillsIOS/Pills/Audio/HapticPlayer.swift`
- Test: `/Users/ben/projects/PillsIOS/PillsTests/ButterflyHugViewModelTests.swift` (created here with a mock; behavior tested in Task 4)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum ButterflySide: String, Sendable { case left, right }`
  - `protocol HapticPlayer: AnyObject { func tap(_ side: ButterflySide); func stop() }`
  - `final class ImpactHapticPlayer: HapticPlayer` (light impact for `.left`, medium for `.right`).

- [ ] **Step 1: Create the HapticPlayer file**

Create `/Users/ben/projects/PillsIOS/Pills/Audio/HapticPlayer.swift`:

```swift
import UIKit

/// Which side of the body the user should tap on the current beat.
enum ButterflySide: String, Sendable {
    case left
    case right
}

/// Abstraction over per-beat haptic feedback so it can be mocked in tests.
/// iPhone has a single actuator: left/right is conveyed visually; the haptic
/// marks each beat with a subtle intensity difference to reinforce rhythm.
protocol HapticPlayer: AnyObject {
    func tap(_ side: ButterflySide)
    func stop()
}

/// Concrete player using system impact feedback generators.
final class ImpactHapticPlayer: HapticPlayer {
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)

    func tap(_ side: ButterflySide) {
        switch side {
        case .left:
            light.impactOccurred()
        case .right:
            medium.impactOccurred()
        }
    }

    func stop() {
        // No continuous engine to stop; impact generators are one-shot.
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project**

Run: `cd /Users/ben/projects/PillsIOS && xcodegen generate`
Expected: project regenerates; `HapticPlayer.swift` is included in the Pills target (folder-based sources).

- [ ] **Step 3: Verify it compiles**

Run: `cd /Users/ben/projects/PillsIOS && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pills.xcodeproj -scheme Pills -destination 'platform=iOS Simulator,id=84F70310-5F7E-4DC7-97BB-5CDD020E811F' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
cd /Users/ben/projects/PillsIOS
git add Pills/Audio/HapticPlayer.swift Pills.xcodeproj project.yml
git commit -m "Add HapticPlayer protocol and impact-based implementation"
```

---

### Task 4: ButterflyHugViewModel (metronome + session lifecycle)

**Files:**
- Create: `/Users/ben/projects/PillsIOS/Pills/ViewModels/ButterflyHugViewModel.swift`
- Test: `/Users/ben/projects/PillsIOS/PillsTests/ButterflyHugViewModelTests.swift`

**Interfaces:**
- Consumes: `BreathingSessionAPI` (`createSession(guideSlug:idempotencyKey:) async throws -> SessionDTO`, `completeSession(id:durationSeconds:) async throws -> SessionDTO`), `BreathingSleeper` (`sleep(for: Duration) async throws`), `TaskBreathingSleeper`, `SessionCompletionQueue.flush(modelContext:api:)`, `PendingSessionCompletion`, `Guide`, `ButterflySide`, `HapticPlayer`, `SessionDTO`.
- Produces: `@MainActor @Observable final class ButterflyHugViewModel` with:
  - init `(guide: Guide, modelContext: ModelContext, haptics: HapticPlayer, api: BreathingSessionAPI = APIClient.shared, sleeper: BreathingSleeper = TaskBreathingSleeper(), now: @escaping () -> Date = Date.init)`
  - `var activeSide: ButterflySide`, `var tapCount: Int`, `var elapsedSeconds: Int`, `var isRunning: Bool`, `var isFinished: Bool`, `var formattedTime: String`
  - `func handleViewAppearance(isAppActive: Bool)`, `@discardableResult func handleAppActivity(isActive: Bool) -> Task<Void, Never>?`, `@discardableResult func handleViewDisappearance() -> Task<Void, Never>?`, `func start() async`, `@discardableResult func stop() -> Task<Void, Never>?`

- [ ] **Step 1: Write the failing tests (mock harness + behavior)**

Create `/Users/ben/projects/PillsIOS/PillsTests/ButterflyHugViewModelTests.swift`:

```swift
import XCTest
import SwiftData
@testable import Pills

// MARK: - Mocks

private actor MockSessionAPI: BreathingSessionAPI {
    struct Completion: Equatable { let id: String; let durationSeconds: Int }
    private var createCount = 0
    private var idempotencyKeys: [String?] = []
    private var completions: [Completion] = []
    private var creationFailure: Error?
    private var completionFailure: Error?

    func configure(creationFailure: Error? = nil, completionFailure: Error? = nil) {
        self.creationFailure = creationFailure
        self.completionFailure = completionFailure
    }

    func createSession(guideSlug: String, idempotencyKey: String?) async throws -> SessionDTO {
        createCount += 1
        idempotencyKeys.append(idempotencyKey)
        if let creationFailure { throw creationFailure }
        return SessionDTO(
            id: "session-\(createCount)", guide_slug: guideSlug,
            started_at: "2026-01-01T00:00:00Z", completed_at: nil, duration_seconds: nil)
    }

    func completeSession(id: String, durationSeconds: Int) async throws -> SessionDTO {
        completions.append(Completion(id: id, durationSeconds: durationSeconds))
        if let completionFailure { throw completionFailure }
        return SessionDTO(
            id: id, guide_slug: "grounding-butterfly-hug",
            started_at: "2026-01-01T00:00:00Z",
            completed_at: "2026-01-01T00:01:00Z", duration_seconds: durationSeconds)
    }

    func snapshot() -> (createCount: Int, keys: [String?], completions: [Completion]) {
        (createCount, idempotencyKeys, completions)
    }
}

private actor ManualSleeper: BreathingSleeper {
    private var pending: [CheckedContinuation<Void, Error>] = []
    private var isShutdown = false

    func sleep(for duration: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled || isShutdown { c.resume(throwing: CancellationError()) }
                else { pending.append(c) }
            }
        } onCancel: {
            Task { await self.cancelFirst() }
        }
    }

    @discardableResult func advanceOne() -> Bool {
        guard !pending.isEmpty else { return false }
        pending.removeFirst().resume()
        return true
    }

    func pendingCount() -> Int { pending.count }

    private func cancelFirst() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(throwing: CancellationError())
    }

    func shutdown() {
        isShutdown = true
        let p = pending; pending.removeAll()
        p.forEach { $0.resume(throwing: CancellationError()) }
    }
}

@MainActor
private final class RecordingHaptics: HapticPlayer {
    private(set) var taps: [ButterflySide] = []
    private(set) var stopCount = 0
    func tap(_ side: ButterflySide) { taps.append(side) }
    func stop() { stopCount += 1 }
}

// MARK: - Tests

@MainActor
final class ButterflyHugViewModelTests: XCTestCase {
    private var container: ModelContainer!
    private var api: MockSessionAPI!
    private var sleeper: ManualSleeper!
    private var haptics: RecordingHaptics!
    private var tracked: [Task<Void, Never>] = []

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(
            for: Guide.self, Session.self, PendingSessionCompletion.self,
            configurations: config)
        api = MockSessionAPI()
        sleeper = ManualSleeper()
        haptics = RecordingHaptics()
    }

    override func tearDown() async throws {
        let tasks = tracked; tracked.removeAll()
        tasks.forEach { $0.cancel() }
        for t in tasks { await t.value }
        await sleeper.shutdown()
    }

    private func makeGuide(tapInterval: Double = 1.0) -> Guide {
        Guide(
            id: UUID().uuidString, slug: "grounding-butterfly-hug", category: "grounding",
            title: "蝴蝶拥抱", summary: "", sortOrder: 9, isActive: true,
            configJSON: #"{"mode":"bilateral_tap","tap_interval":\#(tapInterval),"default_duration":60,"min_duration":15}"#)
    }

    private func makeVM(now: @escaping () -> Date = Date.init) -> ButterflyHugViewModel {
        let vm = ButterflyHugViewModel(
            guide: makeGuide(), modelContext: container.mainContext,
            haptics: haptics, api: api, sleeper: sleeper, now: now)
        vm.handleViewAppearance(isAppActive: true)
        return vm
    }

    private func track(_ task: Task<Void, Never>) { tracked.append(task) }

    func test_start_createsSessionWithIdempotencyKey() async {
        let vm = makeVM()
        track(Task { await vm.start() })
        await waitUntil { await self.sleeper.pendingCount() > 0 }
        let snap = await api.snapshot()
        XCTAssertEqual(snap.createCount, 1)
        XCTAssertNotNil(snap.keys.first ?? nil)
        XCTAssertTrue(vm.isRunning)
        _ = vm.stop()
    }

    func test_tapLoop_alternatesSidesAndCounts() async {
        let vm = makeVM()
        track(Task { await vm.start() })
        await waitUntil { await self.sleeper.pendingCount() > 0 }
        // First beat fired on start (left). Advance to trigger right, then left.
        await sleeper.advanceOne()
        await waitUntil { vm.tapCount >= 2 }
        await sleeper.advanceOne()
        await waitUntil { vm.tapCount >= 3 }
        XCTAssertEqual(haptics.taps.prefix(3), [.left, .right, .left])
        XCTAssertEqual(vm.tapCount, 3)
        _ = vm.stop()
    }

    func test_stop_completesSessionWithElapsedSeconds() async {
        var seconds = 0.0
        let base = Date(timeIntervalSince1970: 0)
        let vm = makeVM(now: { base.addingTimeInterval(seconds) })
        track(Task { await vm.start() })
        await waitUntil { await self.sleeper.pendingCount() > 0 }
        seconds = 42
        let stopTask = vm.stop()
        if let stopTask { track(stopTask); await stopTask.value }
        let snap = await api.snapshot()
        XCTAssertEqual(snap.completions.first?.durationSeconds, 42)
        XCTAssertTrue(vm.isFinished)
    }

    func test_stop_queuesCompletionWhenCompleteSessionFails() async {
        await api.configure(completionFailure: NSError(domain: "x", code: 1))
        let vm = makeVM()
        track(Task { await vm.start() })
        await waitUntil { await self.sleeper.pendingCount() > 0 }
        let stopTask = vm.stop()
        if let stopTask { track(stopTask); await stopTask.value }
        let queued = (try? container.mainContext.fetch(
            FetchDescriptor<PendingSessionCompletion>())) ?? []
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.guideSlug, "grounding-butterfly-hug")
    }

    func test_background_stopsRunningSession() async {
        let vm = makeVM()
        track(Task { await vm.start() })
        await waitUntil { await self.sleeper.pendingCount() > 0 }
        let task = vm.handleAppActivity(isActive: false)
        if let task { track(task); await task.value }
        XCTAssertFalse(vm.isRunning)
        XCTAssertTrue(vm.isFinished)
        let snap = await api.snapshot()
        XCTAssertEqual(snap.completions.count, 1)
    }

    func test_startWhenNotVisible_doesNotCreateSession() async {
        let vm = ButterflyHugViewModel(
            guide: makeGuide(), modelContext: container.mainContext,
            haptics: haptics, api: api, sleeper: sleeper)
        // No handleViewAppearance call -> canStart is false.
        await vm.start()
        let snap = await api.snapshot()
        XCTAssertEqual(snap.createCount, 0)
        XCTAssertFalse(vm.isRunning)
    }

    // MARK: - Helper

    private func waitUntil(
        _ description: String = "condition",
        timeout: TimeInterval = 2,
        _ condition: @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(description)")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/ben/projects/PillsIOS && xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pills.xcodeproj -scheme Pills -destination 'platform=iOS Simulator,id=84F70310-5F7E-4DC7-97BB-5CDD020E811F' -only-testing:PillsTests/ButterflyHugViewModelTests test`
Expected: FAIL to compile — `ButterflyHugViewModel` is undefined.

- [ ] **Step 3: Implement ButterflyHugViewModel**

Create `/Users/ben/projects/PillsIOS/Pills/ViewModels/ButterflyHugViewModel.swift`:

```swift
import Foundation
import SwiftData
import Observation

/// Drives the butterfly hug (蝴蝶拥抱) grounding exercise: a steady alternating
/// left/right tap metronome with free-form start/stop, recorded through the same
/// session pipeline as breathing. Session-lifecycle guards mirror
/// BreathingViewModel (generation counter, canStart gating, background/dismiss
/// auto-stop, idempotency key, offline completion queue).
@MainActor
@Observable
final class ButterflyHugViewModel {

    private enum LifecycleState { case idle, starting, running, stopping, finished }

    private struct StopContext {
        let generation: UInt64
        let sessionID: String?
        let sessionCreationTask: Task<SessionDTO, Error>?
        let timerTask: Task<Void, Never>?
        let elapsedSeconds: Int
        let idempotencyKey: String
    }

    // MARK: - State

    var activeSide: ButterflySide = .left
    var tapCount: Int = 0
    var elapsedSeconds: Int = 0

    var isRunning: Bool {
        switch lifecycleState {
        case .starting, .running, .stopping: return true
        case .idle, .finished: return false
        }
    }

    var isFinished: Bool { lifecycleState == .finished }

    // MARK: - Configuration

    let guide: Guide
    private let tapInterval: Double
    private var timerTask: Task<Void, Never>?
    private var sessionCreationTask: Task<SessionDTO, Error>?
    private var sessionId: String?
    private var sessionStartTime: Date?
    private var currentIdempotencyKey: String = UUID().uuidString
    private var generation: UInt64 = 0
    private var lifecycleState: LifecycleState = .idle
    private var isStarting = false
    private var isViewVisible = false
    private var isAppActive = false

    private var canStart: Bool { isViewVisible && isAppActive }

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private let haptics: HapticPlayer
    private let api: BreathingSessionAPI
    private let sleeper: BreathingSleeper
    private let now: () -> Date

    init(
        guide: Guide,
        modelContext: ModelContext,
        haptics: HapticPlayer,
        api: BreathingSessionAPI = APIClient.shared,
        sleeper: BreathingSleeper = TaskBreathingSleeper(),
        now: @escaping () -> Date = Date.init
    ) {
        self.guide = guide
        self.modelContext = modelContext
        self.haptics = haptics
        self.api = api
        self.sleeper = sleeper
        self.now = now
        self.tapInterval = guide.butterfly?.tapInterval ?? 1.0
    }

    // MARK: - Lifecycle handlers

    func handleViewAppearance(isAppActive: Bool) {
        isViewVisible = true
        self.isAppActive = isAppActive
    }

    @discardableResult
    func handleAppActivity(isActive: Bool) -> Task<Void, Never>? {
        isAppActive = isActive
        return isActive ? nil : stop()
    }

    @discardableResult
    func handleViewDisappearance() -> Task<Void, Never>? {
        isViewVisible = false
        return stop()
    }

    func start() async {
        guard canStart, !isStarting,
              lifecycleState == .idle || lifecycleState == .finished else { return }

        isStarting = true
        defer { isStarting = false }

        await flushPendingCompletions()
        guard canStart else { return }

        generation &+= 1
        let runGeneration = generation
        lifecycleState = .starting
        tapCount = 0
        elapsedSeconds = 0
        activeSide = .left
        sessionId = nil
        sessionStartTime = nil
        let runKey = UUID().uuidString
        currentIdempotencyKey = runKey

        let creationTask = Task {
            try await api.createSession(guideSlug: guide.slug, idempotencyKey: runKey)
        }
        sessionCreationTask = creationTask
        do {
            let session = try await creationTask.value
            guard canStart, lifecycleState == .starting, generation == runGeneration else { return }
            sessionCreationTask = nil
            sessionId = session.id
        } catch {
            guard canStart, lifecycleState == .starting, generation == runGeneration else { return }
            sessionCreationTask = nil
            print("⚠️ Failed to create butterfly session: \(error)")
        }

        guard canStart, lifecycleState == .starting, generation == runGeneration else { return }
        sessionStartTime = now()
        lifecycleState = .running
        timerTask = Task { [weak self] in
            await self?.runTapLoop(generation: runGeneration)
        }
    }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        guard let ctx = beginStop() else { return nil }
        return Task { await self.finishStop(ctx) }
    }

    private func beginStop() -> StopContext? {
        guard lifecycleState == .starting || lifecycleState == .running else { return nil }
        lifecycleState = .stopping
        if let sessionStartTime {
            elapsedSeconds = max(0, Int(now().timeIntervalSince(sessionStartTime)))
        }
        let ctx = StopContext(
            generation: generation,
            sessionID: sessionId,
            sessionCreationTask: sessionCreationTask,
            timerTask: timerTask,
            elapsedSeconds: elapsedSeconds,
            idempotencyKey: currentIdempotencyKey
        )
        sessionStartTime = nil
        sessionId = nil
        sessionCreationTask = nil
        timerTask = nil
        ctx.timerTask?.cancel()
        haptics.stop()
        return ctx
    }

    private func finishStop(_ ctx: StopContext) async {
        await ctx.timerTask?.value

        var completedSessionID = ctx.sessionID
        if let creationTask = ctx.sessionCreationTask {
            do {
                let session = try await creationTask.value
                completedSessionID = completedSessionID ?? session.id
            } catch {
                print("⚠️ Failed to create butterfly session: \(error)")
            }
        }

        if let completedSessionID {
            do {
                _ = try await api.completeSession(id: completedSessionID, durationSeconds: ctx.elapsedSeconds)
                removePendingCompletion(sessionID: completedSessionID)
            } catch {
                print("⚠️ Failed to complete butterfly session: \(error)")
                queuePendingCompletion(
                    sessionID: completedSessionID, guideSlug: guide.slug,
                    durationSeconds: ctx.elapsedSeconds)
            }
        } else {
            queuePendingCompletion(
                sessionID: nil, guideSlug: guide.slug,
                durationSeconds: ctx.elapsedSeconds, idempotencyKey: ctx.idempotencyKey)
        }

        guard lifecycleState == .stopping, generation == ctx.generation else { return }
        lifecycleState = .finished
    }

    // MARK: - Metronome loop

    private func runTapLoop(generation runGeneration: UInt64) async {
        while lifecycleState == .running, generation == runGeneration, !Task.isCancelled {
            haptics.tap(activeSide)
            tapCount += 1
            activeSide = (activeSide == .left) ? .right : .left
            if let start = sessionStartTime {
                elapsedSeconds = max(0, Int(now().timeIntervalSince(start)))
            }
            do {
                try await sleeper.sleep(for: .seconds(tapInterval))
            } catch {
                return
            }
            guard lifecycleState == .running, generation == runGeneration, !Task.isCancelled else { return }
        }
    }

    // MARK: - Pending completion queue (mirrors BreathingViewModel)

    func flushPendingCompletions() async {
        await SessionCompletionQueue.flush(modelContext: modelContext, api: api)
    }

    private func queuePendingCompletion(
        sessionID: String?, guideSlug: String, durationSeconds: Int, idempotencyKey: String? = nil
    ) {
        if let sessionID,
           let existing = (try? modelContext.fetch(
                FetchDescriptor<PendingSessionCompletion>(
                    predicate: #Predicate { $0.sessionID == sessionID }))).first {
            existing.durationSeconds = durationSeconds
            existing.createdAt = now()
            try? modelContext.save()
            return
        }
        modelContext.insert(PendingSessionCompletion(
            sessionID: sessionID, guideSlug: guideSlug,
            durationSeconds: durationSeconds, idempotencyKey: idempotencyKey, createdAt: now()))
        try? modelContext.save()
    }

    private func removePendingCompletion(sessionID: String) {
        guard let existing = (try? modelContext.fetch(
            FetchDescriptor<PendingSessionCompletion>(
                predicate: #Predicate { $0.sessionID == sessionID }))).first else { return }
        modelContext.delete(existing)
        try? modelContext.save()
    }

    // MARK: - Display

    var formattedTime: String {
        String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }
}
```

NOTE for the implementer: verify the `PendingSessionCompletion` initializer parameter names/labels by opening `/Users/ben/projects/PillsIOS/Pills/Models/PendingSessionCompletion.swift` — they are copied from `BreathingViewModel.queuePendingCompletion`. If any label differs, match the model exactly.

- [ ] **Step 4: Regenerate project and run tests to verify they pass**

Run: `cd /Users/ben/projects/PillsIOS && xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pills.xcodeproj -scheme Pills -destination 'platform=iOS Simulator,id=84F70310-5F7E-4DC7-97BB-5CDD020E811F' -only-testing:PillsTests/ButterflyHugViewModelTests test`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/ben/projects/PillsIOS
git add Pills/ViewModels/ButterflyHugViewModel.swift PillsTests/ButterflyHugViewModelTests.swift Pills.xcodeproj project.yml
git commit -m "Add ButterflyHugViewModel with alternating-tap metronome and session lifecycle"
```

---

### Task 5: ButterflyHugView

**Files:**
- Create: `/Users/ben/projects/PillsIOS/Pills/Views/Breathing/ButterflyHugView.swift`
- Test: `/Users/ben/projects/PillsIOS/PillsTests/ButterflyHugViewTests.swift`

**Interfaces:**
- Consumes: `ButterflyHugViewModel`, `Guide`, `ButterflySide`, `ImpactHapticPlayer`.
- Produces: `struct ButterflyHugView: View { let guide: Guide }` — drop-in sibling of `BreathingView` for `navigationDestination`.

- [ ] **Step 1: Write the failing smoke test**

Create `/Users/ben/projects/PillsIOS/PillsTests/ButterflyHugViewTests.swift`:

```swift
import XCTest
import SwiftUI
import SwiftData
@testable import Pills

@MainActor
final class ButterflyHugViewTests: XCTestCase {
    func test_view_instantiatesAndRendersWithoutCrash() {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Guide.self, Session.self, configurations: config)
        let guide = Guide(
            id: UUID().uuidString, slug: "grounding-butterfly-hug", category: "grounding",
            title: "蝴蝶拥抱", summary: "", sortOrder: 9, isActive: true,
            configJSON: #"{"mode":"bilateral_tap","tap_interval":1.0}"#)
        container.mainContext.insert(guide)

        let hosting = UIHostingController(
            rootView: ButterflyHugView(guide: guide)
                .modelContainer(container))
        hosting.loadViewIfNeeded()
        XCTAssertNotNil(hosting.view)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/ben/projects/PillsIOS && xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pills.xcodeproj -scheme Pills -destination 'platform=iOS Simulator,id=84F70310-5F7E-4DC7-97BB-5CDD020E811F' -only-testing:PillsTests/ButterflyHugViewTests test`
Expected: FAIL to compile — `ButterflyHugView` is undefined.

- [ ] **Step 3: Implement ButterflyHugView**

Create `/Users/ben/projects/PillsIOS/Pills/Views/Breathing/ButterflyHugView.swift`:

```swift
import SwiftUI
import SwiftData

struct ButterflyHugView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let guide: Guide

    @State private var viewModel: ButterflyHugViewModel?
    @State private var haptics: HapticPlayer = ImpactHapticPlayer()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            butterfly
                .frame(height: 220)
                .accessibilityElement()
                .accessibilityLabel("蝴蝶拥抱引导，当前\(viewModel?.activeSide.rawValue == "right" ? "右" : "左")侧")

            Text(instruction)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let vm = viewModel, vm.isRunning {
                Text("已轻拍 \(vm.tapCount) 次")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(viewModel?.formattedTime ?? "00:00")
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityLabel("已练习 \(viewModel?.formattedTime ?? "00:00")")

            Spacer()

            controlButton
                .padding(.bottom, 40)
        }
        .navigationTitle(guide.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let vm = viewModel, vm.isRunning {
                    Button("结束") { vm.stop() }
                }
            }
        }
        .onAppear {
            if let viewModel {
                viewModel.handleViewAppearance(isAppActive: scenePhase == .active)
            } else {
                let vm = ButterflyHugViewModel(
                    guide: guide, modelContext: modelContext, haptics: haptics)
                vm.handleViewAppearance(isAppActive: scenePhase == .active)
                viewModel = vm
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel?.handleAppActivity(isActive: newPhase == .active)
        }
        .onDisappear {
            viewModel?.handleViewDisappearance()
        }
    }

    private var instruction: String {
        "双臂交叉，双手轻放于对侧肩上。跟随节奏，左右交替轻拍，同时缓慢呼吸。感觉平静后即可停止。"
    }

    // MARK: - Butterfly wings

    @ViewBuilder
    private var butterfly: some View {
        let active = viewModel?.activeSide ?? .left
        let running = viewModel?.isRunning ?? false
        HStack(spacing: 8) {
            wing(side: .left, isActive: running && active == .left)
            wing(side: .right, isActive: running && active == .right)
        }
    }

    @ViewBuilder
    private func wing(side: ButterflySide, isActive: Bool) -> some View {
        Image(systemName: side == .left ? "hand.raised.fill" : "hand.raised.fill")
            .resizable()
            .scaledToFit()
            .frame(width: 90, height: 140)
            .scaleEffect(side == .left ? -1 : 1) // mirror the left hand
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.35))
            .scaleEffect(isActive ? 1.08 : 1.0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isActive)
            .accessibilityHidden(true)
    }

    // MARK: - Control button

    @ViewBuilder
    private var controlButton: some View {
        if let vm = viewModel {
            if vm.isFinished {
                Button { dismiss() } label: {
                    Text("完成").fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent).tint(.green).padding(.horizontal, 32)
            } else if vm.isRunning {
                Button { vm.stop() } label: {
                    Label("停止", systemImage: "stop.fill").fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.bordered).tint(.red).padding(.horizontal, 32)
            } else {
                Button { Task { await vm.start() } } label: {
                    Label("开始练习", systemImage: "play.fill").fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent).tint(.blue).padding(.horizontal, 32)
            }
        }
    }
}
```

- [ ] **Step 4: Regenerate project and run test to verify it passes**

Run: `cd /Users/ben/projects/PillsIOS && xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pills.xcodeproj -scheme Pills -destination 'platform=iOS Simulator,id=84F70310-5F7E-4DC7-97BB-5CDD020E811F' -only-testing:PillsTests/ButterflyHugViewTests test`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
cd /Users/ben/projects/PillsIOS
git add Pills/Views/Breathing/ButterflyHugView.swift PillsTests/ButterflyHugViewTests.swift Pills.xcodeproj project.yml
git commit -m "Add ButterflyHugView with alternating wing highlight and start/stop control"
```

---

### Task 6: Widen HomeViewModel to fetch and list grounding guides

**Files:**
- Modify: `/Users/ben/projects/PillsIOS/Pills/ViewModels/HomeViewModel.swift` (fetch at line 36; predicate at lines 89-93; `loadFromCache` at lines 60-62)
- Test: `/Users/ben/projects/PillsIOS/PillsTests/HomeViewModelTests.swift`

**Interfaces:**
- Consumes: `HomeAPIProtocol.fetchGuides(category: String?) async throws -> [GuideDTO]`, `Guide.isRenderable`, `GuideDTO`.
- Produces: `HomeViewModel.loadData()` now fetches BOTH `breathing` and `grounding`, caches them, and exposes `guides` filtered to `isRenderable` (so steps-only `grounding-54321` is cached but not listed). `loadFromCache()` applies the same `isRenderable` filter.

- [ ] **Step 1: Write the failing test**

Add to `/Users/ben/projects/PillsIOS/PillsTests/HomeViewModelTests.swift` (match the file's existing mock-API + container setup; the mock must record which categories were requested and can return per-category DTOs). If the existing mock's `fetchGuides` ignores `category`, extend it to branch on the argument:

```swift
func test_loadData_fetchesBreathingAndGrounding_andListsOnlyRenderable() async {
    // Arrange: mock returns one breathing guide, one butterfly guide, one steps-only guide.
    let breathing = GuideDTO(
        id: "b1", slug: "breathing-478", title: "4-7-8", description: "",
        category: "breathing", sort_order: 1, active: true,
        config: GuideConfig(phases: [GuideConfig.BreathPhase(name: "吸气", duration: 4)],
                            steps: nil, mode: nil, tap_interval: nil,
                            default_duration: nil, min_duration: nil))
    let butterfly = GuideDTO(
        id: "g9", slug: "grounding-butterfly-hug", title: "蝴蝶拥抱", description: "",
        category: "grounding", sort_order: 9, active: true,
        config: GuideConfig(phases: nil, steps: nil, mode: "bilateral_tap",
                            tap_interval: 1.0, default_duration: 60, min_duration: 15))
    let stepsOnly = GuideDTO(
        id: "g3", slug: "grounding-54321", title: "5-4-3-2-1", description: "",
        category: "grounding", sort_order: 3, active: true,
        config: GuideConfig(phases: nil,
                            steps: [GuideConfig.GuideStep(sense: "视觉", count: 5, prompt: "x",
                                                          body_part: nil, tense_duration: nil,
                                                          relax_duration: nil, tense_prompt: nil,
                                                          relax_prompt: nil)],
                            mode: nil, tap_interval: nil, default_duration: nil, min_duration: nil))

    let api = MockHomeAPI()   // use the file's existing mock type name
    api.guidesByCategory = ["breathing": [breathing], "grounding": [butterfly, stepsOnly]]

    let vm = HomeViewModel(modelContext: container.mainContext, api: api)
    await vm.loadData()

    let slugs = Set(vm.guides.map { $0.slug })
    XCTAssertTrue(slugs.contains("breathing-478"))
    XCTAssertTrue(slugs.contains("grounding-butterfly-hug"))
    XCTAssertFalse(slugs.contains("grounding-54321"), "steps-only guide must not be listed yet")
    XCTAssertEqual(Set(api.requestedCategories), ["breathing", "grounding"])
}
```

NOTE for the implementer: open `HomeViewModelTests.swift` and reuse its existing mock type, container fixture, and any `requestedCategories` recording. If the current mock does not capture requested categories or branch by category, add those two capabilities to the mock (`var guidesByCategory: [String: [GuideDTO]]` and `private(set) var requestedCategories: [String]`). If `GuideConfig`'s memberwise init is unavailable because it is `Codable` with `let` properties, construct DTOs by decoding JSON instead:
`let butterfly = try! JSONDecoder().decode(GuideDTO.self, from: #"{...}"#.data(using: .utf8)!)`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/ben/projects/PillsIOS && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pills.xcodeproj -scheme Pills -destination 'platform=iOS Simulator,id=84F70310-5F7E-4DC7-97BB-5CDD020E811F' -only-testing:PillsTests/HomeViewModelTests test`
Expected: FAIL — `requestedCategories` is only `["breathing"]` and butterfly slug is absent.

- [ ] **Step 3: Widen the fetch and predicates**

In `HomeViewModel.loadData()`, replace line 36:

```swift
            let guideDTOs = try await api.fetchGuides(category: "breathing")
```

with:

```swift
            let breathing = try await api.fetchGuides(category: "breathing")
            let grounding = try await api.fetchGuides(category: "grounding")
            let guideDTOs = breathing + grounding
```

In `syncGuides(dtos:)`, replace the final fetch descriptor (lines 89-93):

```swift
        let descriptor = FetchDescriptor<Guide>(
            predicate: #Predicate { $0.category == "breathing" && $0.isActive },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        guides = (try? modelContext.fetch(descriptor)) ?? []
```

with:

```swift
        let descriptor = FetchDescriptor<Guide>(
            predicate: #Predicate {
                ($0.category == "breathing" || $0.category == "grounding") && $0.isActive
            },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        let fetched = (try? modelContext.fetch(descriptor)) ?? []
        guides = fetched.filter { $0.isRenderable }
```

In `loadFromCache()`, replace lines 61-62:

```swift
        let guideDescriptor = FetchDescriptor<Guide>(sortBy: [SortDescriptor(\.sortOrder)])
        guides = (try? modelContext.fetch(guideDescriptor)) ?? []
```

with:

```swift
        let guideDescriptor = FetchDescriptor<Guide>(
            predicate: #Predicate {
                ($0.category == "breathing" || $0.category == "grounding") && $0.isActive
            },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        let cached = (try? modelContext.fetch(guideDescriptor)) ?? []
        guides = cached.filter { $0.isRenderable }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/ben/projects/PillsIOS && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pills.xcodeproj -scheme Pills -destination 'platform=iOS Simulator,id=84F70310-5F7E-4DC7-97BB-5CDD020E811F' -only-testing:PillsTests/HomeViewModelTests test`
Expected: PASS (new test + all pre-existing HomeViewModel tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/ben/projects/PillsIOS
git add Pills/ViewModels/HomeViewModel.swift PillsTests/HomeViewModelTests.swift
git commit -m "Fetch and list grounding guides, filtering to renderable exercises"
```

---

### Task 7: Route butterfly guides to ButterflyHugView in HomeView

**Files:**
- Modify: `/Users/ben/projects/PillsIOS/Pills/Views/Home/HomeView.swift:116-118`
- Test: `/Users/ben/projects/PillsIOS/PillsTests/HomeViewRoutingTests.swift`

**Interfaces:**
- Consumes: `Guide.isButterflyHug`, `ButterflyHugView(guide:)`, `BreathingView(guide:)`.
- Produces: `HomeView` `navigationDestination` builds `ButterflyHugView` when `guide.isButterflyHug`, else `BreathingView`.

- [ ] **Step 1: Write the failing routing test**

Create `/Users/ben/projects/PillsIOS/PillsTests/HomeViewRoutingTests.swift`. This tests the pure routing decision via a small helper so it does not depend on navigation internals:

```swift
import XCTest
import SwiftData
@testable import Pills

@MainActor
final class HomeViewRoutingTests: XCTestCase {

    func test_butterflyGuide_isRoutedToButterflyHug() {
        let guide = Guide(
            id: UUID().uuidString, slug: "grounding-butterfly-hug", category: "grounding",
            title: "蝴蝶拥抱", summary: "", sortOrder: 9, isActive: true,
            configJSON: #"{"mode":"bilateral_tap","tap_interval":1.0}"#)
        XCTAssertTrue(guide.isButterflyHug)
        XCTAssertTrue(HomeView.showsButterflyHug(for: guide))
    }

    func test_breathingGuide_isNotRoutedToButterflyHug() {
        let guide = Guide(
            id: UUID().uuidString, slug: "breathing-478", category: "breathing",
            title: "4-7-8", summary: "", sortOrder: 1, isActive: true,
            configJSON: #"{"phases":[{"name":"吸气","duration":4}]}"#)
        XCTAssertFalse(HomeView.showsButterflyHug(for: guide))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/ben/projects/PillsIOS && xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pills.xcodeproj -scheme Pills -destination 'platform=iOS Simulator,id=84F70310-5F7E-4DC7-97BB-5CDD020E811F' -only-testing:PillsTests/HomeViewRoutingTests test`
Expected: FAIL to compile — `HomeView.showsButterflyHug(for:)` is undefined.

- [ ] **Step 3: Add the routing helper and use it**

In `/Users/ben/projects/PillsIOS/Pills/Views/Home/HomeView.swift`, add a static helper inside the `HomeView` struct (e.g. just below the stored properties):

```swift
    /// Routing decision extracted for testability: butterfly hug guides open the
    /// dedicated tapping view; everything else uses the breathing player.
    static func showsButterflyHug(for guide: Guide) -> Bool {
        guide.isButterflyHug
    }
```

Then replace the `navigationDestination` body (lines 116-118):

```swift
            .navigationDestination(item: $selectedGuide) { guide in
                BreathingView(guide: guide)
            }
```

with:

```swift
            .navigationDestination(item: $selectedGuide) { guide in
                if Self.showsButterflyHug(for: guide) {
                    ButterflyHugView(guide: guide)
                } else {
                    BreathingView(guide: guide)
                }
            }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/ben/projects/PillsIOS && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pills.xcodeproj -scheme Pills -destination 'platform=iOS Simulator,id=84F70310-5F7E-4DC7-97BB-5CDD020E811F' -only-testing:PillsTests/HomeViewRoutingTests test`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/ben/projects/PillsIOS
git add Pills/Views/Home/HomeView.swift PillsTests/HomeViewRoutingTests.swift
git commit -m "Route butterfly hug guides to ButterflyHugView from Home"
```

---

### Task 8: Full verification (both repos)

**Files:** none (verification only).

**Interfaces:** n/a.

- [ ] **Step 1: Backend full suite**

Run: `cd /Users/ben/projects/PillsEC2 && ~/projects/PillsEC2/.venv/bin/python -m pytest backend/tests -v`
Expected: PASS (all tests).

- [ ] **Step 2: iOS full suite**

Run: `cd /Users/ben/projects/PillsIOS && xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pills.xcodeproj -scheme Pills -destination 'platform=iOS Simulator,id=84F70310-5F7E-4DC7-97BB-5CDD020E811F' test`
Expected: PASS — previous suite (was 199) plus new butterfly tests.

- [ ] **Step 3: iOS Debug build sanity**

Run: `cd /Users/ben/projects/PillsIOS && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pills.xcodeproj -scheme Pills -destination 'platform=iOS Simulator,id=84F70310-5F7E-4DC7-97BB-5CDD020E811F' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Confirm working trees clean / report status**

Run: `cd /Users/ben/projects/PillsIOS && git status --short && cd /Users/ben/projects/PillsEC2 && git status --short`
Expected: only expected committed changes; report any stray files (e.g. uncommitted `Pills.xcodeproj` diffs) to the user.

- [ ] **Step 5: Manual smoke (optional, report to user)**

Boot the simulator, launch Pills, confirm the Home screen shows a 蝴蝶拥抱 card, tap it, start, watch wings alternate with haptic beats, stop, and confirm a session is recorded in history. Report observations; do not archive/submit (separate release step; requires MARKETING_VERSION > 1.0 and a build bump).

---

## Self-Review

**1. Spec coverage:**
- §3.1 seed entry → Task 1 Step 3. ✔
- §3.2 migration 005 (REQUIRED, populated-table case) → Task 1 Steps 4-5 + tests Steps 1-2. ✔
- §3.3 no route change / grounding filter → Task 1 Step 7 route test. ✔
- §4 GuideConfig additive fields + `butterfly`/`isButterflyHug` → Task 2. ✔ (`isRenderable` added to solve the grounding-54321 collision surfaced during planning.)
- §5 Home fetch widening + routing on mode flag → Tasks 6 (fetch/list) and 7 (routing). ✔
- §6 ButterflyHugViewModel lifecycle + metronome + offline queue → Task 4. ✔
- §7 ButterflyHugView (wings, tap count, timer, start/stop, lifecycle hooks) → Task 5. ✔
- §8 HapticPlayer protocol + UIImpactFeedbackGenerator + mock → Tasks 3 & 4. ✔
- §9 Testing: backend migration/idempotency/grounding filter → Task 1; iOS decode, alternation, createSession+key, completeSession elapsed, offline queue, background stop, routing → Tasks 2, 4, 7. ✔
- §11 xcodegen after new files → Global Constraints + Steps in Tasks 3-5, 7-8. ✔

**2. Placeholder scan:** No "TBD"/"handle edge cases"/"similar to Task N". Every code step contains full code. Two steps carry explicit "open the file and match existing fixture" notes (Task 1 Step 7, Task 6 Step 1) because those tests must bind to pre-existing mock/fixture names that this plan should not invent — the note gives the exact adaptation and a JSON-decode fallback. Acceptable, not a placeholder.

**3. Type consistency:**
- `ButterflySide` (Task 3) used identically in Tasks 4 & 5. ✔
- `HapticPlayer.tap(_ side: ButterflySide)` / `stop()` consistent across Tasks 3, 4, 5. ✔
- `ButterflyConfig(tapInterval:defaultDuration:minDuration:)` defined Task 2, consumed Task 4 init via `guide.butterfly?.tapInterval`. ✔
- `ButterflyHugViewModel` public members referenced by Task 5 view (`activeSide`, `tapCount`, `isRunning`, `isFinished`, `formattedTime`, `handleViewAppearance`, `handleAppActivity`, `handleViewDisappearance`, `start`, `stop`) all defined in Task 4. ✔
- `Guide.isRenderable` defined Task 2, consumed Task 6. `Guide.isButterflyHug` defined Task 2, consumed Task 7. ✔
- `HomeView.showsButterflyHug(for:)` defined and used within Task 7. ✔
- `SessionCompletionQueue.flush(modelContext:api:)` signature matches existing (`PendingSessionCompletion.swift:57`). ✔
- `PendingSessionCompletion` init labels — flagged in Task 4 Step 3 to verify against the model; copied from `BreathingViewModel`. ✔
