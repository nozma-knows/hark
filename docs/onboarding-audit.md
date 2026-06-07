# Onboarding flow audit (ONBO-1)

**Scope:** the first-run experience — from launch to the moment a user can hold
Fn, speak, and see a result. This is an audit, not an implementation. It maps
the current flow exactly as it ships, calls out what works and what costs us
finishers, and proposes a prioritized change list. It closes with a concrete
answer to "how do we test locally and in production without the permissions
overlapping."

Everything below references the code as of this branch. File:line anchors are
clickable.

---

## 1. How it works today

### 1.1 The pieces (codebase map)

```
macos/Hark/UI/Onboarding/
├── OnboardingWindowController.swift   Owns the NSWindow + the 0.5s permission poll
├── OnboardingView.swift               SwiftUI renderer; per-step content + actions
├── OnboardingFlowModel.swift          Pure navigation logic (testable, no AppKit)
├── OnboardingStep.swift               The 6-step enum + canonical order + status enum
├── OnboardingStepLayout.swift         Shared chrome (icon/title/footer) for every step
├── OnboardingProgressDots.swift       The top progress strip
├── OnboardingWelcomeStep.swift        Step 1 body — "what to expect" bullets
├── OnboardingPermissionStep.swift     Shared body for the 3 permission steps
├── OnboardingClaudeStep.swift         Claude auth body (API key / subscription)
└── OnboardingTestStep.swift           "Try it now" — record → local transcribe inline

Supporting:
macos/Hark/App/PermissionsManager.swift   Probes + polls mic / AX / input-monitoring
macos/Hark/App/ClaudeAuth.swift           Resolves API-key vs subscription auth
macos/Hark/App/AppRelauncher.swift        "Restart Hark" recovery for post-update TCC drift
macos/Hark/App/AppDelegate.swift          Wires it together; calls showIfNeeded() at launch
macos/Hark/App/RecordingOrchestrator.swift Re-opens onboarding if a record is attempted w/o perms
```

The split is clean: `OnboardingFlowModel` holds *navigation* logic with an
injected status probe so it can be unit-tested without spinning up SwiftUI or
touching real TCC state (`OnboardingFlowModel.swift:32-45`). The view is a thin
renderer. This is the right shape and the tests reflect it
(`Tests/HarkTests/OnboardingFlowModelTests.swift`, 14 cases).

### 1.2 What the user has to do

Six steps, in this fixed order (`OnboardingStep.swift:28-35`):

| # | Step | What the user does | Where they're taken |
|---|------|--------------------|---------------------|
| 1 | **Welcome** | Reads three bullets, clicks "Get started" | In-app, no system surface |
| 2 | **Microphone** | Clicks "Allow" → macOS in-app permission dialog | In-app dialog (AVFoundation); falls back to Settings only if previously denied |
| 3 | **Accessibility** | Clicks "Open System Settings", finds Hark in the list, flips the toggle | **System Settings → Privacy & Security → Accessibility** |
| 4 | **Input Monitoring** | Same round-trip as Accessibility | **System Settings → Privacy & Security → Input Monitoring** |
| 5 | **Connect Claude** | Pastes an `sk-ant-…` key, OR runs `claude setup-token` in Terminal, OR clicks "Skip for now" | In-app field (key → login Keychain) or Terminal (OAuth) |
| 6 | **Try it now** | Records a clip, watches WhisperKit transcribe it inline; clicks "Done" | In-app; uses the real recorder + transcriber |

Steps 2–4 are the three OS permissions Hark genuinely cannot run without
(microphone to record, Accessibility to create the CGEvent tap, Input
Monitoring so the tap actually receives keystrokes — see `CLAUDE.md` →
Permissions). Step 5 is optional. Step 6 is verification only.

### 1.3 The smart behaviors that already exist

These are good and worth preserving:

- **Smart-skip on open.** `init` jumps straight to the first incomplete step, so
  a user who already granted (e.g.) microphone never sees that screen
  (`OnboardingFlowModel.swift:62-69`, `firstIncompleteStep()` at `:174`).
- **Reactive auto-advance.** While the window is up, a 0.5s timer re-polls
  permissions (`OnboardingWindowController.swift:94-104`). The view watches
  those values and calls `advanceIfCurrentStepCompleted()`
  (`OnboardingView.swift:63-66`) — the instant the user flips the Settings
  toggle, the wizard moves forward on its own. It only advances if the *current*
  step is the one that flipped, so a later grant doesn't yank the user ahead
  (`OnboardingFlowModel.swift:164-167`).
  **Important caveat (see §3.0 + §5):** the navigation *logic* is correct, but
  it can only fire when the OS actually reports the grant **live to the running
  process**. Two things break that — (a) TCC drift, where the binary's signature
  no longer matches what was granted, so the probe keeps returning "denied" no
  matter how long we poll; and (b) `AXIsProcessTrusted()` caching, which on some
  macOS versions doesn't flip within the process that was launched untrusted.
  When either happens the wizard *cannot* auto-advance, because as far as the
  app is concerned the permission genuinely isn't granted. This is the
  #1 cause of "I granted it but I'm stuck" reports, and it is especially common
  in local dev (see §5.1).
- **Honest permission copy + single action.** After #25, the AX / IM steps just
  open the right Settings pane (one predictable action) instead of firing a
  system dialog *and* a redirect (`OnboardingView.swift:266-289`).
- **Post-update TCC recovery.** If Settings shows the toggle ON but the running
  process is still untrusted (stale TCC after a binary update), the step surfaces
  "Already granted? Restart Hark to apply" → `AppRelauncher.relaunch()`
  (`OnboardingPermissionStep.swift:65-73`, `AppRelauncher.swift`).
- **Global auto-revive.** `PermissionsManager.onPermissionGranted` →
  `hotkey.installIfNeeded()` (`AppDelegate.swift:180-182`) means granting AX/IM
  installs the hotkey tap live, without an app restart.
- **Try-it proves the real path.** Step 6 runs the actual recorder + transcriber,
  so "Done" means mic + WhisperKit + the hot path are confirmed, not just that
  the user clicked through (`OnboardingTestStep.swift`).

### 1.4 How the app registers progress  ← (the important subtlety)

**There is no persisted "onboarding complete" flag.** Progress is derived live,
and the *only* gate that decides whether onboarding re-appears is
`PermissionsManager.allGranted`:

```
allGranted = microphone == .granted && accessibilityTrusted && inputMonitoringGranted
```
(`PermissionsManager.swift:73-75`)

- At launch, `AppDelegate.applicationDidFinishLaunching` →
  `onboardingController.showIfNeeded()`, which shows the window **iff** a
  permission is still missing (`OnboardingWindowController.swift:46-53`,
  `AppDelegate.swift:260`).
- If the user tries to record before granting everything,
  `RecordingOrchestrator.ensureReady()` re-opens onboarding
  (`RecordingOrchestrator.swift:196-203`).
- Closing the window or finishing simply calls `onComplete` → `close()`. **It
  persists nothing** (`OnboardingWindowController.swift:64-67`,
  `OnboardingView.swift:67-69`). `windowWillClose` only stops the poll timer
  (`OnboardingWindowController.swift:112-118`).
- Per-step "have we shown the system prompt yet" lives in view-local `@State`
  (`accessibilityRequested`, `inputMonitoringRequested` in
  `OnboardingView.swift:25-26`) and **resets every time the window opens**.

The practical consequences of "progress == the three OS grants":

1. **Claude and Try-it are invisible to the gate.** Once the three permissions
   are granted, onboarding never reappears — regardless of whether the user ever
   connected Claude or ran the test. That's intentional for permissions, but it
   means we have no signal for "did they reach the aha moment."
2. **No funnel data at all.** There is no analytics/telemetry beyond crash
   reporting (`grep` for analytics finds only `CrashReporter`/`HttpCrashSink`).
   We cannot currently answer "what % of installs grant all three permissions"
   or "where do people drop off" — which is exactly the metric ONBO is about.
3. **A returning user mid-setup gets the smart-skip,** which is good — they land
   on the exact step they still need.

---

## 2. What's good

- **Architecture.** Navigation logic is isolated and unit-tested; the view is
  declarative; the permission probe is injectable. Adding/reordering steps is
  cheap.
- **The flow auto-advances** on real system changes — the single biggest UX win
  for a permissions wizard, and it's already here.
- **Copy is honest** about what macOS does and doesn't allow apps to do.
- **The hard-won failure modes are handled:** silent Input-Monitoring denial,
  post-update TCC drift, the "Allow opens two things" confusion (all from the
  #23–#25 dogfooding round).
- **Try-it verifies the real pipeline**, not a fake success state.

## 3. What's weak / what costs us finishers

Ordered by estimated impact on completion rate.

### 3.0 "Granted but stuck" — the permission reads as denied to the process (HIGHEST)
This is the failure that surfaced during local testing of this very audit, and
it's worth pulling to the top because it makes the otherwise-correct
auto-advance look broken. The wizard polls and the logic is sound, but the
underlying probe (`AXIsProcessTrusted()` / `IOHIDCheckAccess()` /
`AVCaptureDevice.authorizationStatus`) keeps returning "not granted" for the
running binary, so there's nothing to advance *to*. Two distinct causes:

1. **TCC binds a grant to (bundle id + code signature).** If the running binary
   was signed differently from the one that was granted — a Release build vs a
   dev build sharing `co.milbo.hark`, or an **ad-hoc** dev build whose cdhash
   changes on every rebuild — Settings shows Hark toggled on while the process
   reads denied. (Confirmed locally: the stable `Hark Dev` cert was missing, so
   dev builds were ad-hoc and lost their grant on every rebuild.)
2. **`AXIsProcessTrusted()` caches per process.** On some macOS versions the
   trust value is fixed at launch; flipping the toggle won't update it until the
   process restarts. This is why `AppRelauncher.relaunch()` exists — but the
   restart link only appears *after* the user has clicked through once
   (`OnboardingPermissionStep.swift:68`), and that "have they clicked" flag is
   view-local `@State` that resets every reopen (`OnboardingView.swift:25-26`).

This PR addresses cause (1) for the dev/test workflow directly — see §5.
Cause (2) and the recovery-affordance reset are follow-ups (§4 items 7 + new).

### 3.1 The two System Settings round-trips are the drop-off cliff (HIGH)
Steps 3 and 4 eject the user into System Settings to hunt for "Hark" in a long
list and flip a toggle — twice. This is *the* classic macOS-utility abandonment
point. We auto-advance once they succeed, but we give **no visual guidance** to
get them there: no annotated screenshot, no "look for the Hark row" pointer, no
GIF. Every extra second of "wait, where is it?" loses people.
- *Where:* `OnboardingView.swift:138-192`, `OnboardingPermissionStep.swift`.

### 3.2 We can't measure the funnel (HIGH)
No onboarding analytics exist. "Maximize the number of people who finish" is
unfalsifiable without per-step instrumentation (reached / granted / skipped /
abandoned, plus time-to-grant). This should arguably be the *first* change —
everything else in this section is a hypothesis until we can measure it.
- *Where:* nothing today; nearest pattern is the opt-in `HttpCrashSink`.

### 3.3 Claude is silently skippable, and skipping degrades "the real experience" (MED)
The ticket's north star is getting people to "feel the real experience." Without
Claude, Hark only produces *raw* transcripts — no polish, no voice commands. Yet
the Claude step's primary button is literally "Skip for now" when unresolved
(`OnboardingView.swift:203`), and once skipped the user is never reminded. A user
can finish onboarding and conclude "it just types what I say." Consider: make the
value concrete before the skip, and/or surface a persistent, dismissible "Connect
Claude to unlock polish + commands" nudge (the pill or menu) afterward.
- *Where:* `OnboardingView.swift:194-211, 299-305`.

### 3.4 Onboarding can be dismissed mid-setup with no consequence or nudge (MED)
The window is `.closable` (`OnboardingWindowController.swift:69-75`) and closing
with permissions missing is a silent no-op. The user is then in a half-set-up
state where the app does nothing until they happen to try recording. There's no
breadcrumb (menu-bar badge, pill hint) saying "setup incomplete — finish here."
The "Welcome…" menu item exists (`HarkApp.swift:98-100`) but is undiscoverable
in this moment.

### 3.5 Try-it requires a model download that isn't surfaced here (MED)
Step 6 calls `transcriber.transcribe(...)`. On a fresh install the WhisperKit
model may still be downloading (warmed in the background at launch,
`AppDelegate.swift:265`). If the user reaches Try-it before the download
finishes, the failure copy is generic ("Transcription failed…",
`OnboardingTestStep.swift:169-173`) and doesn't say "model still downloading,
give it a moment." First impression of the marquee feature should never read as
a plain error.

### 3.6 The recovery affordance resets on reopen (LOW)
`accessibilityRequested` / `inputMonitoringRequested` are view-local `@State`
(`OnboardingView.swift:25-26`), so a user stuck in post-update TCC drift who
*reopens* the window must click "Open System Settings" once more before the
"Restart Hark to apply" link reappears (`OnboardingPermissionStep.swift:68`).
Minor, but it's exactly the population already having a bad day.

### 3.7 Stale comment (LOW / doc hygiene)
`OnboardingWindowController.swift:114-116` says the re-open surface is "future
PR" — it already shipped as the "Welcome…" menu item. Worth correcting so the
next reader trusts the comments.

---

## 4. Recommended change list (prioritized)

Each is a candidate follow-up ticket; none are implemented in this PR (this is
the audit). Rough impact/effort in brackets.

1. **Instrument the funnel.** [impact: high, effort: med] Emit a step-reached /
   step-completed / step-skipped / abandoned event per step + time-to-grant,
   through an opt-in sink mirroring `HttpCrashSink`. Without this we're guessing.
   *Do this first.*
2. **Add inline guidance to the AX / IM steps.** [high, low-med] An annotated
   screenshot or short looping clip showing the exact toggle, plus "Hark is
   already in this list — just switch it on." Attacks the #3.1 cliff directly.
3. **Persist an onboarding-completed marker** (UserDefaults) so we can (a)
   distinguish "first run" from "returning, perms revoked," (b) decide when to
   *stop* nudging, and (c) feed the funnel. [med, low]
4. **Make the Claude value explicit + add a post-skip nudge.** [med, med] Show
   what polish/commands unlock before the Skip; if skipped, a dismissible
   reminder in the menu/pill. Drives people to "the real experience."
5. **Surface model-download state in Try-it.** [med, low] If WhisperKit isn't
   loaded yet, show "Preparing on-device model…" with progress instead of letting
   the first transcribe fail generically.
6. **Don't let the window close into a dead end.** [med, low] Either keep a
   menu-bar/pill "Finish setup" affordance visible while perms are missing, or
   confirm-on-close. Re-open is already wired; just make it discoverable.
7. **Lift the recovery `@State` into the flow model** so "Restart Hark to apply"
   survives a reopen. [low, low]
8. **Fix the stale comment** in `OnboardingWindowController`. [low, trivial]

---

## 5. Local + production testing without permissions overlapping

This is the second explicit question in the ticket, and it has a concrete root
cause. **This PR implements the fix below** (project.yml + a reset script);
the rest of this section explains why.

### 5.0 The other half: unstable dev signing (fix: run the existing script)
Independent of the bundle-id collision, a dev build only keeps its TCC grant
across rebuilds if it's signed with a **stable** identity. The repo already has
`scripts/setup-dev-signing.sh` to create the `Hark Dev` cert for exactly this
reason — but it has to actually be run on each dev machine. If it hasn't been,
builds fall back to ad-hoc signing, the cdhash changes every build, and TCC
re-denies on every rebuild (this was the case observed while auditing). There's
no code fix here — it's a setup step, now called out as non-optional in
`CLAUDE.md` → Dev workflow.

### 5.1 Why permissions collide today

macOS TCC keys a permission grant on **(bundle identifier + code-signing
identity)**. Both build configs ship the **same** bundle ID:

```
PRODUCT_BUNDLE_IDENTIFIER: co.milbo.hark   # base — shared by Debug AND Release
```
(`macos/project.yml:189`)

…but they're signed differently (`macos/project.yml:198-213`):

- **Debug** → self-signed `"Hark Dev"` cert, hardened runtime off.
- **Release** → `"Developer ID Application"`, hardened runtime on, notarized.

So the dev build and the shipping build present the *same* identity to TCC
(`co.milbo.hark`) but with *different* signatures. When you grant Accessibility
to one and then run the other, System Settings often shows Hark as "on" while
`AXIsProcessTrusted()` returns false for the running process — the grant is
bound to the other binary's signature. This is the documented
"dev/release TCC collision" (resolved manually today with
`tccutil reset Accessibility co.milbo.hark` / `tccutil reset All co.milbo.hark`),
and it's the same drift the in-app "Restart Hark to apply" recovery papers over.

### 5.2 The fix (implemented in this PR): give the dev build its own identity

Make local and production **two distinct apps to TCC** so their grants never
touch each other. Implemented as:

- Debug config now sets `PRODUCT_BUNDLE_IDENTIFIER: co.milbo.hark.dev`
  (`macos/project.yml`, Debug config); Release stays `co.milbo.hark`.
- Result: granting permissions to `co.milbo.hark.dev` and to `co.milbo.hark` are
  independent TCC rows. You can have the dev build and the released build both
  permitted at once; iterating on the dev build never disturbs the production
  grant, and vice-versa.

`PRODUCT_NAME` is deliberately left as `Hark` so the existing build paths,
`open …/Debug/Hark.app`, and the `pkill` relaunch pattern keep working. Both
apps therefore show as "Hark" in the Settings permission lists but are distinct
TCC entries — toggle each once.

Things verified while implementing (no runtime coupling to the bundle id):

- The login-Keychain service is the literal constant `"co.milbo.hark"`
  (`Keychain.swift:16`), **not** the bundle id — so a saved API key stays
  readable under either build.
- The only self-`bundleIdentifier` read is for the *frontmost* app
  (`PolishPane.swift:75`), not Hark itself.
- Entitlements declare no `keychain-access-group` / app-group, so nothing is
  scoped to the bundle id (`Signing/Hark.entitlements`).
- No test asserts the app bundle id (the `co.milbo.hark.*` hits in tests are
  UserDefaults keys).

Other call-outs (left intentionally unchanged):

- The log subsystem string `"co.milbo.hark"` is hard-coded in many `Logger(...)`
  calls and is **independent** of the bundle ID — leave it as-is; diagnostics
  stay consistent. (Changing it is unnecessary and would fragment `log show`
  queries.)
- In-process `Notification.Name` strings (`AppDelegate.swift:9`) are
  process-local — unaffected by the bundle-ID split.
- The test target already uses its own ID (`co.milbo.hark.tests`,
  `project.yml:226`) so tests are unaffected.
- Sparkle/appcast and notarization are Release-only and keep the production ID.

### 5.3 The reset helper (added in this PR)

`scripts/reset-tcc.sh` clears a wedged grant state during testing. By default it
resets both the dev and release bundle ids across all three services; pass a
bundle id to scope it:

```
./scripts/reset-tcc.sh                  # reset dev + release, then re-prompt on next launch
./scripts/reset-tcc.sh co.milbo.hark.dev   # reset just the dev build
```

With §5.2 in place you'll rarely need it, and when you do you can reset the dev
identity in isolation without touching production grants.

### 5.4 Net recommendation

1. **Run `scripts/setup-dev-signing.sh`** so dev builds are stably signed —
   without it, grants die on every rebuild regardless of bundle id. *(setup)*
2. Debug bundle id is now `co.milbo.hark.dev` — local and production are
   permanently non-overlapping in TCC. *(implemented)*
3. `scripts/reset-tcc.sh` for the occasional wedge. *(implemented)*
4. Keep the in-app "Restart Hark to apply" recovery — it's the right fix for the
   *end-user* post-update drift, which is a different scenario from the
   dev/prod collision.

---

## 6. Summary

The wizard is well-built and already handles the painful macOS edge cases. The
two things standing between us and "maximize finishers" are **(a) we can't see
the funnel** and **(b) the two System Settings round-trips have no guidance** —
fix those first. Progress is tracked purely via the three OS grants and nothing
is persisted, which is fine for permissions but blinds us to the Claude/Try-it
steps. For testing, the local/production permission overlap is a single root
cause — a shared bundle ID across Debug and Release — and is fixed by giving the
dev build its own identity.
