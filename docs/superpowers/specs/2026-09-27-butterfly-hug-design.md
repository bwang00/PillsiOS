# 蝴蝶拥抱 (Butterfly Hug) — Design Spec

Date: 2026-09-27
Status: Approved (design), pending implementation plan
Repos: `PillsIOS` (client) + `PillsEC2` (backend)

## 1. Goal

Add a "calm down" grounding exercise — the butterfly hug (蝴蝶拥抱), a bilateral
alternating-tap self-soothing technique — to Pills 1.1. The user crosses their
arms, rests hands on their shoulders/upper arms, and alternately taps left and
right at a steady rhythm while breathing slowly. The app guides the rhythm and
records the practice like any other guided session.

Success criteria:
- Butterfly hug appears on the Home screen as a guide card alongside breathing.
- Tapping it opens a dedicated exercise view with an alternating left/right
  visual (butterfly wings) and a haptic tap on each beat.
- The user starts and stops freely; elapsed time is recorded through the
  existing session pipeline so streaks, totals, and history work unchanged.
- Backend serves the guide from the DB (data-driven, no client hardcoding of
  copy/timing) via the existing `GET /api/guides` endpoint.

## 2. Decisions (from brainstorming)

- **Architecture**: Backend-seeded grounding guide + iOS category routing.
  Reuses the existing guide pipeline (fetch, SwiftData cache, offline, session
  recording, stats). Opens the door to surfacing the already-seeded
  `grounding-54321` guide later.
- **Cue modality**: Haptics + visual. Constraint: iPhone has a single haptic
  actuator, so left/right is conveyed **visually** (alternating wing highlight);
  a **haptic transient fires on each beat** with a subtle intensity difference
  between the left and right beat to reinforce rhythm. No voice/TTS for taps
  (TTS every second for minutes is intrusive and drifts from rhythm).
- **Duration**: Free-form. Start on tap, stop on tap, elapsed time recorded.
  A `default_duration` and `min_duration` are carried in config for copy/hints
  only, not to force an end.
- **Client engine**: Approach A — a dedicated `ButterflyHugViewModel` +
  `ButterflyHugView` that mirror the proven `BreathingViewModel` session
  lifecycle but replace the breath-phase machine with a simple alternating-tap
  metronome. Chosen over (B) extracting a shared `PracticeSessionController`
  (larger refactor of just-shipped, approved code — higher regression risk) and
  (C) forcing taps into `BreathingViewModel` phases (abuses TTS/circle
  semantics, poor fit for free-form stop).

## 3. Backend (`PillsEC2`)

### 3.1 Seed entry

Append to `backend/seeds/guides.json`:

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

`category = "grounding"` is already in `VALID_CATEGORIES`, so no validator
change is needed.

### 3.2 Migration (REQUIRED)

`_load_seeds` only inserts guides when the `guides` table is **empty**. Prod
already has 8 guides, so seeding alone will NOT surface butterfly hug on the
live DB. Add a versioned migration following the existing `schema_migrations`
pattern:

- `_BUTTERFLY_HUG_MIGRATION_VERSION = "005_butterfly_hug_guide"`
- Guard: `SELECT 1 FROM schema_migrations WHERE version = ?`; if absent, run
  `INSERT OR IGNORE INTO guides (...) VALUES (...)` with the seed row above,
  commit, then record the version. `INSERT OR IGNORE` keyed on the unique
  `slug`/`id` makes it idempotent and safe alongside a fresh-DB seed load.

### 3.3 Routes

No route changes. `GET /api/guides` already accepts `category` as a Query
filter and returns active guides ordered by `sort_order`. `GET
/api/guides?category=grounding` will include the new guide.

## 4. iOS data model (`PillsIOS`)

`Pills/Models/Guide.swift`:

- Extend `GuideConfig` with an optional nested config (additive — existing
  decoding of `phases`/`steps` is unaffected):

```swift
struct GuideConfig: Codable {
    let phases: [BreathPhase]?
    let steps: [GuideStep]?
    let mode: String?             // "bilateral_tap" for butterfly hug
    let tap_interval: Double?     // seconds per beat
    let default_duration: Int?    // hint only
    let min_duration: Int?        // hint only
    // ...existing BreathPhase / GuideStep unchanged
}
```

- Add a `Guide` accessor mirroring `phases`:

```swift
var isButterflyHug: Bool { /* decoded config mode == "bilateral_tap" */ }
var butterfly: ButterflyConfig? { /* decoded from configJSON */ }
```

  where `ButterflyConfig` exposes `tapInterval` (default 1.0),
  `defaultDuration`, `minDuration`.

## 5. iOS Home routing (`PillsIOS`)

- `HomeViewModel` currently hardcodes `api.fetchGuides(category: "breathing")`
  and a SwiftData predicate `category == "breathing"`. Widen both to include
  `grounding` so butterfly hug is fetched, cached, and listed. (Either two
  fetch calls merged, or fetch all and filter to the allowed categories —
  chosen during planning; predicate must match the fetch set.)
- `HomeView` `.navigationDestination(item: $selectedGuide)` currently always
  builds `BreathingView(guide:)`. Route by guide: if `guide.isButterflyHug` →
  `ButterflyHugView(guide:)`; otherwise → `BreathingView(guide:)` (unchanged).
  Category alone (`grounding`) is not sufficient because `grounding-54321` is a
  steps-based guide — route on the `mode`/`isButterflyHug` flag, not category.

## 6. ButterflyHugViewModel (`PillsIOS`)

`@MainActor @Observable final class ButterflyHugViewModel`, structurally
mirroring `BreathingViewModel`'s session lifecycle but with a metronome loop.

- **Reused dependencies**: `BreathingSessionAPI` (createSession with
  idempotency key / completeSession), `BreathingSleeper`,
  `SessionCompletionQueue`, `ModelContext`, `now: () -> Date`. A new
  `HapticPlayer` protocol (mockable) wraps the beat feedback.
- **State**: `enum Side { case left, right }`; `activeSide: Side`;
  `tapCount: Int`; `elapsedSeconds: Int`; `isRunning` derived from a private
  `LifecycleState { idle, starting, running, stopping, finished }`; a
  `generation: UInt64` guard; `canStart = isViewVisible && isAppActive`.
- **Lifecycle handlers** identical in spirit to breathing:
  `handleViewAppearance(isAppActive:)`, `handleAppActivity(isActive:)` (stops
  on background), `handleViewDisappearance()` (stops on dismiss).
- **start()**: same re-entrancy claim + offline-queue flush + re-validate
  `canStart` before opening a session; snapshot a fresh idempotency key;
  create session via `api.createSession(guideSlug:idempotencyKey:)`; on success
  enter `.running` and launch the metronome `Task`.
- **Metronome loop**: while running and generation matches, alternate
  `activeSide` each iteration, fire `hapticPlayer.tap(side:)`, increment
  `tapCount`, sleep `tapInterval` via the injected sleeper, and update
  `elapsedSeconds` from `now()` relative to `sessionStartTime` (~1/sec).
- **stop()**: `beginStop()` cancels the loop, stops haptics, computes
  `elapsedSeconds`; `finishStop()` awaits the in-flight creation task if any,
  then `api.completeSession(id:durationSeconds:)`; on failure, queue via
  `SessionCompletionQueue` (carrying the idempotency key when createSession
  never returned an id). Ends in `.finished`. Free-form: no minimum enforced to
  finish — elapsed is recorded as-is (min_duration is a UI hint only).

## 7. ButterflyHugView (`PillsIOS`)

- A butterfly graphic with two wings; the wing matching `activeSide`
  highlights/scales on each beat (SwiftUI animation driven by `activeSide` +
  `tapCount`).
- Shows `tapCount` and formatted elapsed time, plus a short instruction line
  (cross arms, hands on shoulders, follow the rhythm).
- A single large 开始 / 停止 button bound to `start()` / `stop()`.
- Reuses the offline banner and app-active lifecycle hooks the same way
  `BreathingView` does (`.onAppear`, scene-phase observation → view model
  handlers).
- Portrait, Chinese localization, Dynamic Type + VoiceOver labels consistent
  with existing views.

## 8. HapticPlayer

```swift
protocol HapticPlayer: Sendable {
    func tap(_ side: ButterflyHugViewModel.Side)
    func stop()
}
```

Concrete impl uses `UIImpactFeedbackGenerator` — `.light` for one side,
`.medium` for the other — to give a felt rhythm without a Core Haptics engine.
A mock records taps for tests.

## 9. Testing (TDD)

Backend (pytest):
- Migration inserts butterfly hug into a **non-empty** guides table and is
  idempotent on re-run (no duplicate).
- `GET /api/guides?category=grounding` includes slug `grounding-butterfly-hug`
  with `mode = bilateral_tap` in config.

iOS (XCTest, `PillsTests`):
- `GuideConfig`/`Guide.butterfly` decodes the butterfly config; `isButterflyHug`
  is true for `mode = bilateral_tap` and false for breathing/steps guides.
- `ButterflyHugViewModel` alternates `activeSide` on each injected-sleeper beat
  and increments `tapCount`.
- `start()` calls `createSession` with a non-nil idempotency key; `stop()` calls
  `completeSession` with elapsed seconds.
- On `completeSession` failure the completion is queued (offline path).
- Backgrounding (`handleAppActivity(isActive:false)`) stops a running session.
- HomeView routing selects `ButterflyHugView` for a butterfly guide and
  `BreathingView` for a breathing guide.

## 10. Out of scope / follow-ups

- Surfacing `grounding-54321` and other seeded non-breathing guides (the routing
  widening makes this easy later, but this spec only ships butterfly hug).
- Read-aloud for AI chat vs. tightening the disclosure wording (separate 1.1
  decision).
- Marketing version bump (>1.0) at next ASC submission.

## 11. Release notes

- Backend deploy first (migration is additive and backward-compatible; existing
  clients ignore the extra guide since they filter to `breathing`).
- iOS ships in 1.1. `xcodegen generate` required after adding new `.swift`
  files (folder-based sources) and to regenerate Info.plist.
