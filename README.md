# Hark

> Voice → Linear tickets → Claude Code.

Hark is a macOS menu bar app: hold a hotkey, speak, release. Your voice is transcribed
on-device by [WhisperKit](https://github.com/argmaxinc/WhisperKit), turned into a
structured Linear ticket draft by the [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview),
refined in a floating panel via chat, and either filed directly or handed to Claude Code
to start working on.

The app is single-purpose and out of the way: menu bar status item, summoned panel,
ESC to dismiss. Native SwiftUI, non-sandboxed, Developer ID signed and notarized.

## Status

Pre-alpha. v1 lands across 15 milestone PRs; walking skeleton at PR 6, first useful
Linear-creating version at PR 10, public-ready v1 at PR 15.

## Requirements

- macOS 14.0 (Sonoma) or later, Apple Silicon
- Xcode 16+
- [Homebrew](https://brew.sh) for dev tooling

## Bootstrapping the project

The Xcode project is generated from [`project.yml`](./project.yml) via
[XcodeGen](https://github.com/yonaskolb/XcodeGen) — `.xcodeproj/` is gitignored.

```sh
# One-time tooling
brew install xcodegen swiftlint swiftformat openssl@3

# Set up stable dev signing — keeps macOS TCC (Accessibility, Microphone)
# grants across rebuilds. Creates a self-signed cert in your login keychain.
./scripts/setup-dev-signing.sh

# Install git hooks (lint + format on commit)
./scripts/install-hooks.sh

# Generate the Xcode project from project.yml
xcodegen generate

# Open in Xcode
open Hark.xcodeproj
```

> **Why the dev signing step?** Hark needs Accessibility and Microphone
> permissions. Without a stable code-signing identity, macOS TCC ties trust
> to each rebuild's `cdhash` — you'd re-grant on every change. The script
> creates a `Hark Dev` self-signed cert; `project.yml` is pinned to that
> identity. CI builds fall back to ad-hoc via xcodebuild overrides.

Or build from the CLI:

```sh
xcodebuild -project Hark.xcodeproj -scheme Hark \
           -destination 'platform=macOS' -configuration Debug build
```

Run the tests:

```sh
xcodebuild -project Hark.xcodeproj -scheme Hark \
           -destination 'platform=macOS' -configuration Debug test
```

## Project layout

```
Hark/
├── Hark/           # Swift app sources (App, Audio, Transcription, Hotkey, …)
├── Sidecar/        # Bun + Claude Agent SDK bridge (added in PR 7)
├── Tests/          # XCTest targets
├── scripts/        # install-hooks.sh, build-sidecar.sh, release.sh
├── .githooks/      # pre-commit (swiftformat + swiftlint on staged files)
├── project.yml     # XcodeGen — source of truth for the Xcode project
├── .swiftlint.yml  # lint rules (strict)
└── .swiftformat    # formatting rules (matched to swiftlint)
```

## Auth

Hark never bundles Claude credentials. On first run it detects what's available on
your machine and falls back to a guided "bring your own auth" flow:

1. An existing `claude` CLI session (`CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`), or
2. An `ANTHROPIC_API_KEY` you supply (stored only in your Keychain).

Linear API tokens are also Keychain-only.

## License

[MIT](./LICENSE) © 2026 Noah Milberger
