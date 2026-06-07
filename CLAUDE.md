# Hark — Developer Guide

A macOS voice-control desktop app. Hold the Fn (🌐) key, speak, release — WhisperKit transcribes locally, Claude polishes (or executes voice commands), the result drops into the floating pill or pastes into the focused input. BYO Anthropic credentials.

## Repo layout

```
hark/
├── macos/                    Swift app + bundled Bun sidecar
│   ├── Hark/                 App source (3.6k LOC)
│   │   ├── App/              AppDelegate, AppState, FileLogger, UpdateManager,
│   │   │                     RecordingOrchestrator, ClaudeAuth, Permissions
│   │   ├── Audio/            AVAudioEngine → 16 kHz mono Float32
│   │   ├── Transcription/    WhisperKit lifecycle, model selection, timeout
│   │   ├── Hotkey/           CGEvent tap, latch-upgrade trigger logic
│   │   ├── Agent/            Bun sidecar process + NDJSON RPC
│   │   ├── Insert/           InputInserter (AX paste into focused input)
│   │   ├── UI/               Pill view, panel controller, settings, onboarding
│   │   ├── Resources/        Assets.xcassets, AppIcon.icns, bundled sidecar
│   │   └── Generated/        Info.plist (xcodegen output, gitignored)
│   ├── Sidecar/              TypeScript Bun sidecar source
│   │   └── src/
│   │       ├── dispatch/     Deterministic voice-command dispatchers
│   │       └── llm/          Hybrid LLM transport (Messages API + SDK)
│   ├── Tests/HarkTests/      XCTest unit + integration tests
│   ├── scripts/              build-sidecar.sh, release.sh, notarize.sh, etc.
│   ├── Signing/              Hark.entitlements, ExportOptions.plist
│   └── project.yml           XcodeGen source of truth (versions, configs)
├── web/                      Next.js 16 landing site (tellhark.com)
│   ├── lib/version.ts        Auto-generated; read from macos/project.yml
│   └── scripts/sync-version.mjs   Prebuild step that keeps version in sync
├── video/                    Remotion promo (placeholder, replace before launch)
├── assets/                   Shared brand artwork (hark-mark.png canonical)
└── .github/workflows/        ci.yml (PR), release.yml (tag push)
```

## Locked architectural decisions

| Layer | Choice | Why |
|---|---|---|
| Framework | Swift / SwiftUI + AppKit hybrid | Native menu bar app + floating NSPanel |
| Concurrency | Swift 6 strict, `@MainActor` pervasive | Justified `@preconcurrency` (WhisperKit, AVFoundation, AppKit) + 5 documented `@unchecked Sendable` boxes (each with inline lifetime + thread-safety contract) |
| State | Single `AppState` (Observable, MainActor) | No scattered @State; SwiftUI views derive everything |
| Transcription | WhisperKit `small.en` default, prewarmed at launch | First call would otherwise pay ~22s CoreML wake-up |
| Hotkey | CGEvent tap (`.cgSessionEventTap`, `.listenOnly`) | Requires Accessibility AND Input Monitoring (Catalina+) |
| Claude | Bundled Bun-compiled sidecar, NDJSON over stdio | Single static binary; Zod-validated protocol; auto-respawn with identity-checked termination handler |
| Sandboxing | OFF | App spawns child processes (`claude`, `git`, Terminal); incompatible with sandbox |
| Distribution | Developer ID + notarize + Sparkle, R2 hosting | Public-track from day 1 — never an App Store app. Sparkle auto-checks are GATED off until `SUPublicEDKey` is populated (verifies signed updates only). |
| Auth | Detect local `claude` OAuth token; else BYO API key | Anthropic ToS forbids redistribution of subscription auth |
| Crash capture | Two-stage: async-signal-safe breadcrumb + next-launch finalizer | Signal handler does only `write(2)` to a pre-opened FD. Full report formats on next launch under `~/Library/Logs/Hark/crashes/`. Validated end-to-end with `fork(2)` + `raise(SIGSEGV)` integration tests. |
| Logging | os_log primary + rotating file mirror via `FileLogger` | Serial DispatchQueue serializes writes; 2 MB rotation, one generation kept; `flushSynchronously()` for tests. |

## State machine (the heart of the app)

```
                  ┌────────────────┐
                  │     Idle       │ ←──────────────────┐
                  └───────┬────────┘                    │
                          │ Fn down (hotkey or pill)    │
                          ▼                             │
                  ┌────────────────┐                    │
              ┌───│   Recording    │                    │
              │   └───────┬────────┘                    │
              │           │ Fn up / click stop          │
              │           ▼                             │
              │   ┌────────────────┐                    │
              │   │ Transcribing   │ ←─ WhisperKit      │
              │   └───────┬────────┘                    │
              │           │ branch on trigger           │
              │           ▼                             │
              │  ┌────────┴────────┐                    │
              │  │                 │                    │
              │  ▼  .dictate       ▼ .command           │
              │ ┌──────────┐  ┌──────────────┐          │
              │ │ Polishing│  │  Executing   │          │
              │ └────┬─────┘  └──────┬───────┘          │
              │     │               │                   │
              │  paste / show      command result       │
              │     │               │                   │
              └─────┴───────────────┴───────────────────┘
                    (auto-clear after 5s)
```

`RecordingOrchestrator` owns this state machine. `AppDelegate` is just AppKit glue (lifecycle, notifications, settings window). `PanelRootView` is purely reactive — it reads `AppState` + `recorder.state` + `transcriber.state`, derives `PanelViewModel.Mode`, renders the matching pill.

## Modifier truth table (latch-upgrade)

The Fn key + modifier combinations:

| Held when Fn released | Trigger | Action |
|---|---|---|
| Fn alone | `.dictate` | Polished transcript appears in the pill |
| Fn + Ctrl | `.insert` | Polished transcript pasted into the focused text input |
| Fn + Shift | `.command` | Raw transcript sent to Claude Agent SDK as a voice command |
| Fn + Ctrl + Shift | `.command` | Shift wins (rarer, more deliberate gesture) |

**Latch-upgrade rule:** during a held Fn session, the trigger can only escalate (`.dictate → .insert → .command`), never demote. Users routinely release Shift/Ctrl a moment before Fn — without the latch that brief gap would silently downgrade the gesture.

Live truth table tests: `Tests/HarkTests/HotkeyManagerTests.swift`.

## Sidecar protocol (NDJSON over stdio)

Request envelope (`Sidecar/src/protocol.ts`):
```json
{"kind":"request","id":"42","method":"polishTranscript","params":{"text":"..."}}
```

Response envelope:
```json
{"kind":"response","id":"42","ok":true,"result":{"polished":"...","changed":true,"usage":{...}}}
```

Error envelope (`ok:false`):
```json
{"kind":"response","id":"42","ok":false,"error":"...","code":"unknown_method"}
```

Methods:
- `ping` — liveness check with echo
- `polishTranscript` — punctuation/casing/filler cleanup via Claude (8s timeout)
- `executeCommand` — voice command → macOS action, two-tier (60s timeout):
    1. **Dispatcher path** (`Sidecar/src/dispatch/`) — deterministic match
       on the common 90% of voice commands (open app, open url, chrome
       profile routing, shortcuts, screencapture, clipboard). Sub-100ms,
       free, bypasses the LLM entirely.
    2. **LLM fallback** (`Sidecar/src/llm/`) — for anything the
       dispatchers don't claim. Hybrid auth: `MessagesClient` (Anthropic
       Messages API + Haiku 4.5 + prompt caching) when `ANTHROPIC_API_KEY`
       is set; `SdkClient` (Claude Agent SDK) when the user authenticates
       via Claude Code subscription OAuth. Both verify a Bash tool call
       actually fired before returning `succeeded: true` — catches the
       "Claude Code denied Bash via settings.json, model narrated fake
       success" failure mode.

The Swift side (`AgentSidecar.swift`) handles per-request timeouts via `Task.detached` racing against the response continuation. Sidecar crashes auto-respawn on the next request.

## Permissions

Three system permissions are required:

1. **Microphone** (AVFoundation) — to record audio
2. **Accessibility** (`AXIsProcessTrusted`) — to create the CGEvent tap
3. **Input Monitoring** (`IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`) — to actually receive keyboard events from the tap (Catalina+; silent denial path if missing)

`PermissionsManager` polls all three on `didBecomeActive`, runs a 30-second fast-poll burst (250ms cadence) right after the user is sent to System Settings, and fires `onPermissionGranted` the moment any toggle flips. AppDelegate wires this to `hotkey.installIfNeeded()` so the global hotkey auto-revives without an app restart.

## Distribution

`scripts/release.sh <version>`:
1. **Archive** — `xcodebuild archive` (Release config, hardened runtime)
2. **Export** — `xcodebuild -exportArchive` (Developer ID sign)
3. **Notarize** — `notarytool submit --wait` + `stapler staple`
4. **DMG** — `create-dmg` with `Hark.app` + Applications symlink
5. **Sparkle appcast** — `generate_appcast` signs DMG with EdDSA key
6. **R2 upload** — versioned + `latest.dmg` + `appcast.xml`

Tag push triggers `.github/workflows/release.yml` which runs the same script with secrets injected. See the workflow file for the full secret list.

## Tests

Run with `xcodebuild test`. **247 tests** across 26 test files, all passing in ~16s, zero `swiftlint --strict` violations. Release builds clean with `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`.

Coverage map:

| File | Tests | What it covers |
|---|---:|---|
| `AgentSidecarTests` | 6 | Ping round-trip, unknown method, per-request timeout, timeout→recovery, auto-respawn after stop, concurrent request ID correlation |
| `AppStateTests` | 4 | `ClaudeUsage` accumulation + lastUsedAt advancement |
| `AppDelegateSettingsRecognitionTests` | 11 | Settings-window recognition (identifier+title contains-match, hidden windows, multiple matches, negative cases) |
| `ClaudeAuthTests` | 23 | Auth detection precedence (OAuth env > `~/.claude/` > API key env), empty-string handling, `claude` binary search order, `isResolved` + `shortLabel` helpers, sidecar env composition |
| `PerformanceTests` | 5 | Assertion-style budgets: FileLogger throughput, mode derivation, breadcrumb decode, hotkey resolve, usage accumulation |
| `CrashReporterTests` | 14 | Breadcrumb format round-trip, decode rejection (size/magic/zeros), formatter output, signal name table, finalizer end-to-end (read+delete+report) |
| `CrashReporterSignalIntegrationTests` | 2 | `fork(2)` child raises real SIGSEGV / SIGABRT, parent reads + decodes breadcrumb |
| `FileLoggerTests` | 14 | Init creates dir, log levels, ISO8601 timestamps, ordering preservation, concurrent writes don't tear, rotation at threshold, single-generation cap, Unicode bodies, empty bodies, 1000-line stress |
| `HarkTests` | 1 | Bundle loads sanity |
| `HotkeyManagerTests` | 6 | Modifier truth table + latch-upgrade priorities |
| `OnboardingFlowModelTests` | 14 | Step wizard navigation: initial landing, skip-complete forward walk, back navigation, can-continue gating, skip-claude, reactive auto-advance |
| `PanelViewModelTests` | 15 | UI mode derivation priority order (10 base branches + 5 boundary cases) |
| `PermissionsManagerTests` | 14 | `allGranted` aggregation, grant-callback firing, fast-poll lifecycle, settings-deep-link starts polling |
| `RecordingOrchestratorTests` | 12 | Permission gating, hotkey start/stop pairing, pill toggle, manual cancel |
| `RecordingOrchestratorPipelineTests` | 13 | Dictate vs command branching, polish fallback, error pill surfacing, server-envelope errors, sidecar timeouts, trigger latching |
| `TranscriberTests` | 4 | Model-not-loaded guard, initial state, cancel safety |
| `UpdateManagerTests` | 10 | Sparkle signing-key gate against 9 dictionary fixtures (nil, missing, empty, whitespace, populated, non-string types) |

Tests requiring the bundled sidecar binary auto-skip if it's missing (run `./scripts/build-sidecar.sh` first). Tests that use `fork(2)` go through a tiny C bridge at `Tests/HarkTests/HarkForkBridge.c` (Swift marks `fork` unavailable; the bridge is test-only and never linked into the production binary).

## Diagnostics

- **System log:** `log show --predicate 'subsystem == "co.milbo.hark"' --info --last 5m`
- **File log:** `~/Library/Logs/Hark/hark.log` (rotates at 2 MB, keeps one generation)
- **Settings → General** has a "Reveal in Finder" button for the log files

## Dev workflow

```bash
# Initial setup
brew install xcodegen swiftlint swiftformat create-dmg awscli
cd macos
./scripts/setup-dev-signing.sh    # creates "Hark Dev" cert in login keychain
bun install --cwd Sidecar         # sidecar dependencies
./scripts/build-sidecar.sh        # compile sidecar to single binary
xcodegen generate                 # write Hark.xcodeproj from project.yml
open Hark.xcodeproj               # build + run from Xcode

# Or from CLI
xcodebuild -project Hark.xcodeproj -scheme Hark -configuration Debug \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Hark.app

# When relaunching during dev — kill ALL Hark instances, not just Debug
pkill -9 -f 'Hark.app/Contents/MacOS/Hark'
```

### Permissions while testing (mic / Accessibility / Input Monitoring)

`setup-dev-signing.sh` is **not optional** — it creates the stable `Hark Dev`
cert so TCC remembers your grants across rebuilds. Without it, builds fall back
to ad-hoc signing (new cdhash every build), so macOS treats each rebuild as a
new app and the permission you granted last time reads as denied — which leaves
you stuck in onboarding with the wizard unable to auto-advance.

The Debug build uses the bundle id `co.milbo.hark.dev` (Release uses
`co.milbo.hark`), so a locally-built Hark and an installed Release Hark are
**separate** TCC entries and never clobber each other's grants. Each is granted
once, independently, in System Settings → Privacy & Security.

If a grant gets wedged (Settings shows Hark on, but the app still acts
unpermitted — common right after a signing-identity change), reset and re-prompt:

```bash
./scripts/reset-tcc.sh            # clears dev + release grants, then re-prompt on next launch
```

## Conventions

- One file per type. File header doc-comment explains the type's role.
- `@MainActor` everywhere unless a thread hop is needed (e.g., AVAudioEngine tap callback). Off-actor closures hop back via `Task { @MainActor in }`.
- Errors logged with `privacy: .public` so support bundles don't redact the actual reason.
- Important events ALSO go through `FileLogger.shared` for the user-visible log file.
- No force-unwraps except at framework boundaries where the API guarantees non-nil (e.g., AX casts).
- Tests cover pure logic; integration tests cover the sidecar smoke path.
