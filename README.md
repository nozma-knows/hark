# Hark

> Voice control for macOS. Hold Fn, speak, release.

Hark is a macOS app that turns your voice into text, paste, or commands — anywhere on your Mac.

- **Hold `Fn`** — push-to-talk dictation. Transcript appears in a pill at the bottom of the screen.
- **Hold `⌃ + Fn`** — polishes the transcript and pastes it wherever your cursor is.
- **Hold `⇧ + Fn`** — voice command. *"Open Chrome with my work profile and go to YouTube."* *"Take a screenshot."* *"Search Google for the weather in Tokyo."* *"Run shortcut Daily Briefing."*

Transcription runs on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit) on the Apple Neural Engine. Voice commands route through a deterministic dispatcher for the common cases (open app, open URL, Chrome-profile routing, shortcuts, screenshot, clipboard) and fall back to Claude — via the Anthropic Messages API (Haiku 4.5 + prompt caching) when you supply an API key, or via the [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview) when you only have a Claude Code subscription. Hark is bring-your-own-Claude — no bundled credentials.

**Download:** [tellhark.com/latest.dmg](https://tellhark.com/latest.dmg) (signed + notarized · Apple Silicon · macOS 14+)
**Site:** [tellhark.com](https://tellhark.com)

## Repo layout

```
hark/
├── macos/    Swift app + Bun sidecar — the actual product
├── web/      Next.js landing site (tellhark.com)
├── video/    Remotion compositions for the promo / hero video
├── assets/   Brand artwork (logo source, etc.)
├── README.md
└── LICENSE
```

Each package is self-contained; CI and tooling assume `cd <pkg>` first.

## macOS app — develop & build

The Xcode project is generated from [`macos/project.yml`](./macos/project.yml) via [XcodeGen](https://github.com/yonaskolb/XcodeGen); `*.xcodeproj` is gitignored.

```sh
# One-time tooling
brew install xcodegen swiftlint swiftformat openssl@3 bun

# Set up stable dev signing — keeps macOS TCC (Accessibility, Microphone)
# grants across rebuilds. Creates a self-signed cert in your login keychain.
cd macos
./scripts/setup-dev-signing.sh

# Install git hooks (lint + format on commit)
./scripts/install-hooks.sh

# Generate the Xcode project from project.yml
xcodegen generate

# Open in Xcode
open Hark.xcodeproj
```

Or build from the CLI (from inside `macos/`):

```sh
xcodebuild -project Hark.xcodeproj -scheme Hark \
  -destination 'platform=macOS' -configuration Debug build
```

### Cutting a signed + notarized release

Requires Apple Developer Program enrollment and the `Developer ID Application` cert installed locally, plus an App Store Connect API key stored as the `hark-notary-api` notarytool keychain profile. The release script is self-contained — read `macos/scripts/release.sh` if you want the play-by-play.

```sh
cd macos
./scripts/release.sh 0.1.5   # archive → sign → notarize → staple → dmg → upload
```

If `R2_ACCOUNT_ID` is set + `aws --profile r2` is configured, the script also uploads to Cloudflare R2 so the new build appears at `dl.tellhark.com/Hark-0.1.5.dmg` and `dl.tellhark.com/latest.dmg`. Sparkle auto-update is gated off in `project.yml` (`SUPublicEDKey` empty) until the EdDSA signing key is generated and committed — see the comments around `SUPublicEDKey` in `project.yml` for the four-step turn-on procedure.

## Landing site

```sh
cd web
pnpm install
pnpm dev          # http://localhost:3000
pnpm build        # production build
```

Deployed on Vercel from `/web` (Root Directory setting in the Vercel project). Next.js 16, App Router, Tailwind 4.

## Promo video

```sh
cd video
pnpm install
pnpm dev               # opens Remotion Studio for live preview
pnpm build:promo       # render out/hark-promo.mp4
```

Remotion 4 + React 19. The current `Promo` composition is a placeholder hero loop; replace with real demo footage when ready.

## Auth (macOS app)

Hark never bundles or transmits Claude credentials. The Settings → Claude tab detects what's already on your machine and falls back to a guided BYO flow. Precedence (highest first):

1. `ANTHROPIC_API_KEY` exported in your shell, **or**
2. `ANTHROPIC_API_KEY` you paste into Settings → Claude (stored in your macOS login Keychain), **or**
3. `CLAUDE_CODE_OAUTH_TOKEN` from your existing `claude setup-token` session, **or**
4. `~/.claude/` directory from a local Claude Code install.

API key takes precedence because it activates the Messages API path (Haiku 4.5 + prompt caching) — faster than the Agent SDK and unaffected by your local Claude Code `~/.claude/settings.json` tool-permission rules. Subscription auth still works; it just routes through the SDK transport.

## License

[MIT](./LICENSE) © 2026 Noah Milberger
