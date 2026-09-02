# Pills iOS

Native SwiftUI app for the Pills wellness platform — breathing exercises and AI chat coach.

## Requirements

- macOS with Xcode 15+
- iOS 17+ target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Setup

```bash
# Install XcodeGen
brew install xcodegen

# Generate Xcode project
cd PillsiOS
xcodegen generate

# Open in Xcode
open Pills.xcodeproj
```

## Configuration

Set the API URL via environment variable in your Xcode scheme:
- `PILLS_API_URL` → `https://pills.blueping.xyz`

Or it defaults to `https://pills.blueping.xyz` if not set.

## Project Structure

```
Pills/
├── App/            # @main entry point, SwiftData container
├── Models/         # SwiftData @Model + Codable DTOs
├── Network/        # APIClient actor, Endpoints
├── Auth/           # Sign in with Apple (AuthManager)
├── Audio/          # TTSPlayer (AVAudioPlayer wrapper)
├── ViewModels/     # @Observable MVVM view models
└── Views/          # SwiftUI views
    ├── Onboarding/ # Sign in with Apple
    ├── Home/       # Guide cards, stats, recent sessions
    ├── Breathing/  # Animated circle + phase timer
    ├── Chat/       # AI chat with typing indicator
    └── History/    # Session history with pagination
```

## Backend

This app talks to the Pills FastAPI backend at `pills.blueping.xyz`:
- `GET /api/guides?category=breathing` — Fetch breathing guides
- `POST /api/sessions` — Create session
- `PATCH /api/sessions/:id` — Complete session
- `POST /api/tts` — Synthesize speech (edge-tts)
- `POST /api/ai-chat` — AI chat (Qwen3 Max)
- `POST/GET /api/conversations` — Conversation management

## Build

```bash
# Debug build
xcodebuild -project Pills.xcodeproj -scheme Pills -destination 'platform=iOS Simulator,name=iPhone 15' build

# Archive for TestFlight
xcodebuild -project Pills.xcodeproj -scheme Pills -archivePath build/Pills.xcarchive archive
```

## Notes

- **Sign in with Apple**: Requires Apple Developer account. Set your Team ID in `project.yml`.
- **Entitlements**: `Pills/Pills.entitlements` enables Sign in with Apple capability.
- **SwiftData**: Local cache for guides, sessions, conversations. Auto-syncs from server.
