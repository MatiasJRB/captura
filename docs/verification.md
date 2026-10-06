# Local verification — 2026-10-04

This checks a contribution prototype, not a commercial product or broad device support.

Passed:
- 16 worker tests: metadata/hashes, account/folder gates, dedupe, revoked/expired auth
  handling, retry/quarantine, VAD required, empty output, stale-output rejection.
- 8 reader/Android-boundary tests: fictional fixture, JSON CLI, text escaping,
  symlink/traversal/export guards, empty/error records, dark start and independent signing.
- 17 Android JUnit tests (10 sync, 7 battery observation); debug APK compiled/signed.
- Local clean Git clone built with a different application ID, its own new development
  key, no copied runtime config/keys/build output. Same Mac/SDK and dependency caches;
  not evidence of a fresh machine or a separately configured phone.
- Real local whisper.cpp small + Silero VAD: short synthesized speech produced the
  intended phrase; generated silence produced empty `no_speech_detected` output.
  Both retained `review_only`; no personal recording or Drive account was used.
- Desktop/mobile dark reader, search/no-match/details; mobile no horizontal overflow.
  Independent scoped UI review: **Pass**; dynamic result-count announcement resolved.
- Source-tree publication safety check. Signing keys, APKs and screenshots ignored.

Not verified:
- New OAuth project/client/account end-to-end or a separate physical Android device.
- iOS/Linux/Windows, all Android manufacturers, isolated app battery cost.
- Screen reader on an actual assistive device, native audio playback across browsers.
- Final dependency/license audit for a distributed APK, final name or public release.

No app installed, existing capture runtime changed, external message sent or repository
published as part of this extraction. Private verification audio and receipts stay
outside this source repo; the committed demo is hand-authored fictional text only.

## Local voice / dictated-notes source update

- Public neutral build and a fresh local clean clone: `testDebugUnitTest` +
  `assembleDebug` passed, 29 JVM tests, 0 failures/errors.
- Python worker: 18 tests passed; CLI/reader/Android-boundary: 9 tests passed.
- Publication tree safety check passed; reviewed full reachable source history for
  forbidden recording/key/database/APK files and private configuration literals.
  This is a bounded safety check, not a complete secret-scanning guarantee.
- Optional model grammar vocabulary checked; inert acoustic/parser regression used
  private local test material and synthetic phrases. None is included in Git.
- Real-device installation, updated one-screen layout and live dictated-note
  end-to-end behavior remain **unverified for this update**. No release APK uploaded.

## iOS client

Checked 2026-10-06 on an Apple-silicon Mac with macOS 26.1 and **Xcode 26.1** (iOS 26.1
SDK and simulator). The setup guide targets Xcode 27 on macOS 26.6 or later; that
combination has not been run yet.

Passed:
- `CapturaCore` package (`swift test`): 454 tests. OAuth/PKCE, token handling, Drive
  client and resumable upload, upload queue, sync policy, worker contract, recorder
  rotation policy.
- App-hosted tests in the iPhone 16e simulator: 219 tests, 0 failures, 5 skipped. Three
  real-microphone tests are opt-in and were not run, so no microphone audio was
  recorded. One Data Protection test is skipped because the simulator does not report
  protection classes. One Google-configuration test needs a configured build: a second
  run with a fictional `Captura.local.xcconfig` written by `ios/scripts/configure.py`
  passed it (and skipped its unconfigured twin). The synthetic test audio that run left
  in the simulator was deleted.
- Device compile for `generic/platform=iOS` with signing disabled: build succeeded.
- Setup helpers, with fake Xcode, `defaults`, `xcrun`, `pgrep`, ffmpeg, whisper-cli and
  rclone on `PATH` and a real but isolated Git: 24 tests for `configure.py`/`check.py`
  (value validation, no overwrite, team detection, `--adopt-xcode-team` restoring only
  the project file, refusals) and 16 for `capture init/doctor/pin` and probe hints
  (permissions, model sizes, rclone remote checks without printing secrets).
- `check.py` against the real Xcode 26.1 here: it resolved a configured bundle ID and
  team through `xcodebuild -showBuildSettings`, confirming the `#include?` of the local
  file works.
- Python suites pass on Python 3.9.6 (the one Xcode provides) and 3.14.

Not verified yet:
- Installing on a physical iPhone with a free Personal Team, the 7-day reinstall and the
  3-app limit; Developer Mode and trust prompts. The Spanish path "Configuración >
  General > Admón. de dispositivos y VPN" is from Apple's es-MX support page; the
  wording "Modo de desarrollador" and the developer-app section name are not.
- Team detection from Xcode preferences: no Apple Account was signed in to Xcode on the
  test Mac, so the `IDEProvisioningTeams` / `IDEProvisioningTeamByIdentifier` layout is
  read tolerantly but untested against a real Xcode 27 profile. `--adopt-xcode-team` is
  the fallback.
- `xcrun devicectl` output with a real iPhone attached (field names are read defensively;
  the check is informational only).
- Real Google sign-in with an iOS client, Internal versus External consent screens,
  `admin_policy_enforced`, and whether the Desktop client in the same project sees the
  phone's `drive.file` uploads (Google does not document it; `capture probe` decides).
- Recording on a device: background continuation, calls and other apps interrupting,
  low storage, Shortcuts/Action Button start.
- The launchd example in `docs/worker.md` was not installed.
