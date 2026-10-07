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
- Uploader/worker contract: `WorkerFixtureContractTests` (7 Swift tests) runs the real
  upload queue, Drive client and sync engine against the in-memory Drive fake, including
  an interrupted and resumed upload, and pins the result in `tests/fixtures/ios_contract/`.
  `tests/test_ios_contract.py` (15 tests) runs the unmodified worker on that fixture,
  with negative controls (tampered checksum, corrupted bytes, shared file or folder,
  wrong parent, oversize, wrong MIME type). Drive is emulated, not called.
- Re-run after merging the pause notice, the contract and the setup helpers (same Mac,
  Xcode 26.1): `swift test` 461 tests; hosted tests on the iPhone 17 simulator 252 tests,
  0 failures, 6 skipped (the opt-in microphone and speech tests, the Data Protection test
  and the configured-build test); Debug and Release device compiles; Python 18 tests in
  `worker/` and 64 in `tests/` on 3.9.6 and 3.14; publication check.

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

## iOS client: pause notice and speech proof — 2026-10-06

Simulator and host only (Xcode 26.1, iPhone 17 simulator, macOS 26.1). No iPhone, Google
account, Drive folder or microphone was used.

- Pause notice: when recording pauses or stops while Captura is not on screen
  (interruption, interruption that cannot continue, disconnected microphone, failed
  restart after a route change or audio reset, low storage, write failure), the app
  posts one local notification in Spanish, such as "Captura se pausó" / "Abrí la app
  para seguir grabando.". It withdraws the notice when recording continues by itself,
  when the person starts or stops, and when the app opens. Permission is asked right
  after the first successful Grabar (after the microphone permission), never at
  launch. If notices are denied, recording works exactly as before. Covered by hosted
  tests with a fake notifier. The project has no entitlements file and no push
  capability, and the simulator build is signed with no entitlements. Local
  notifications need neither, so a free Personal Team is enough.
- Speech without a microphone: `say -v "Flo (Español (México))"` made two synthetic
  Spanish phrases (5.4 s and 5.8 s). The opt-in hosted test
  `SpeechFixtureRecordingTests` plays each file at 48 kHz into an offline
  `AVAudioEngine`. From there the audio goes through the production
  `AVAudioCaptureEngine` tap and converter, `RecorderController` rotation,
  `ChunkWriter` and the AAC encoder. The test then copies the closed `.m4a` chunks
  out. The unmodified `worker.transcribe` (whisper.cpp small + Silero VAD) then
  produced:
  - one chunk: "Hola Berna, esta es una prueba de captura en el iPhone. Mañana
    visitamos la obra a las 10." (`needs_review`, `review_only: true`, listed by
    `capture list`);
  - forced 4 s rotation, cut between "visitamos" and "la obra": "Hola Verna, esta es
    una prueba de captura en el iphone, mañana visitamos." | "de la obra a la vez.";
  - second phrase, one chunk and cut inside "materiales": both halves
    transcribed, with the cut audible only as the phrase split.

  Rotation is gapless. The decoded sample counts of the two chunks add up exactly to
  the single-chunk run. Around the cut, the audio matches the single-chunk run at lag 0
  (correlation 0.9999 and 1.0000). "a las diez" → "a la vez" in the short second half
  is a recognition error on a 1.8 s fragment. The same error appears when the original
  file is cut at the same second without the app.
- Found while testing: the input tap delivers whole buffers only. When capture stops,
  up to one tap buffer (about 85 ms at 48 kHz) at the very end is not saved. This
  affects Detener, not rotation. On a phone this is the moment the person presses the
  button.

Not verified: notices on a physical iPhone (lock screen, a real call, Focus modes),
whether iOS wakes a suspended app for every interruption end, and the larger
`large-v3-turbo` model on these chunks.

## iOS and worker setup: fixes from a first-time install test — 2026-10-06

A first-time install test followed `docs/ios.md` and `docs/worker.md` literally on a Mac
with no Apple Account, Google account or rclone remote. Its findings were fixed in the
guides, `ios/scripts/configure.py`, `ios/scripts/check.py`, `bin/capture` and the app's
setup messages. Same Mac as above: macOS 26.1, **Xcode 26.1**, iPhone 17 simulator.

Checked here:
- `swift test`: 462 tests. Hosted app tests on the iPhone 17 simulator: 252 tests,
  0 failures, 6 skipped (the opt-in microphone and speech tests, which were not run, so
  no microphone audio was recorded; the Data Protection test; the configured-build test).
- Device compile for `generic/platform=iOS` with `CODE_SIGNING_ALLOWED=NO`: with no
  settings file and no team it builds, as before. With no settings file and
  `DEVELOPMENT_TEAM` set, the build stops with the `SetupCheck.swift` message that points
  to `configure.py`. With a fictional settings file written by `configure.py` and a team,
  it builds. The fictional settings file was deleted afterwards.
- Python: 18 tests in `worker/` and 91 in `tests/`, on Python 3.9.6 and 3.14.3; the
  publication check. New tests cover `configure.py --force` keeping the saved team,
  lowercase bundle IDs, `Already configured`, `--adopt-xcode-team` with Xcode's
  upgrade stamps, the `check.py` summary when only the team is missing, `check.py --help`,
  `capture set`, `init --root/--language`, pin placeholders and Drive folder links,
  missing remote versus expired authorization, and the plain `Next:` lines.
- The plain `Next:` / `Or:` lines were read through a pseudo-terminal: once split the
  way a shell does, no argument keeps a literal quote character. With stdout and stderr
  piped, stderr stays empty.
- The step 3 `read` lines in zsh with piped fictional input (`Got 22 characters.`), not
  with a real rclone or Google client.
- `python3 scripts/check_public_tree.py --default-branch` in this clone **fails**:
  `origin/main`, as last fetched, has no `docs/ios.md`, `ios/scripts/configure.py` or
  `ios/scripts/check.py`. A fresh clone would not have them either. This is the
  install test's blocker, and only merging and pushing the iOS branch fixes it. Nothing
  was pushed.

Still not verified (do these before handing the guides to someone, see
[release](release.md#before-handing-out-the-setup-guides)):
- Xcode 27 on macOS 26.6 or later. Whether it offers "Update to recommended settings"
  for this project and which lines that changes. `--adopt-xcode-team` ignores only
  `LastUpgradeCheck` and `LastSwiftUpdateCheck`; for anything else it prints the undo
  command.
- A free Personal Team: team detection from Xcode's preferences, Run on a physical
  iPhone, Developer Mode, trusting the developer. Also whether Xcode registers the
  placeholder bundle ID as soon as a team is picked in the Signing menu; the build-time
  stop comes after that, so the guide's step 6.1 warning is the real protection.
- Google sign-in with a real iOS client.
- Doctor against a real rclone remote (type, scope, client ID shape, token, own client)
  and its `ready_with_warnings` state: only fictional `rclone.conf` sections were used.
  Whether the Desktop client sees the phone's `drive.file` uploads is still open.
- The text of Homebrew's "Next steps" on Apple silicon. The two PATH lines in the worker
  guide are the usual ones for `/opt/homebrew`; they were not run here.

## iOS and worker setup: second install test — 2026-10-07

A second first-time install test (same kind of Mac, no Apple Account, Google account or
rclone remote) found 17 more points. Fixed in `configure.py`, `check.py`, `bin/capture`
and `worker/onboarding.py`, the guides, a Spanish quick start (`docs/ios.es.md`) and an
agent setup procedure (`.claude/skills/captura-setup/SKILL.md`). Same Mac: macOS 26.1,
**Xcode 26.1**, iPhone 17 simulator.

Checked here:
- The project's upgrade stamps now say 2700 (`LastUpgradeCheck`, `LastSwiftUpdateCheck`,
  the scheme's `LastUpgradeVersion`). Xcode 26.1 builds and tests the project with them
  and leaves them unchanged.
- `swift test`: 462 tests. Hosted app tests on the iPhone 17 simulator: 252 tests,
  0 failures, 6 skipped (the opt-in microphone and speech tests, which were not run, so
  no microphone audio was recorded; the Data Protection test; the configured-build test).
  Device compile for `generic/platform=iOS` with `CODE_SIGNING_ALLOWED=NO`: succeeded.
- Python: 18 tests in `worker/` and 103 in `tests/`, on Python 3.9.6 and 3.14.3; the
  publication check. New tests cover the guide's placeholders and examples being refused
  (bundle ID, client ID, Workspace domain), capital letters refused with the lowercase
  value, `configure.py --bundle-id` alone, the same exit status for "no team" on every run,
  scheme-only and pre-settings project changes in `check.py`, one command or one sentence
  per `Next:` line in both tools, doctor's `Warn:` lines and labels in words, the model
  fallback order, scopes other than `drive.file`/`drive.readonly`, the refused-account
  command, probe without counters, and the default-branch check refusing a foreign origin.
- The pseudo-terminal test helper waited forever when the doctor JSON did not fit the
  pipe buffer macOS gave it; it now reads stdout while the command runs.

Still not verified: everything listed in the previous section, in particular whether
Xcode 27 offers "Update to recommended settings" for reasons other than the stamps, and
the labels of a Spanish macOS 26.6 (Configuración del Sistema, Acerca de esta Mac,
Usuarios y grupos, Permitir siempre), which follow Apple's Latin American Spanish naming
but were not seen on a Mac set to Spanish. `check_public_tree.py --default-branch` still
fails here until the iOS branch is merged and pushed.

## Setup values from a password manager — 2026-10-07

`ios/scripts/configure.py --from` and the new `capture drive-setup` read setup values
through `scripts/secret_refs.py`: `op://Vault/Item/field` (`op read`), `op://Vault/Item`
(`op item get --format json`, keeping only the named fields), `keychain://service/account`
(`security find-generic-password -w`), `env:NAME`, or a hidden prompt. drive-setup writes
the rclone remote into rclone's config file (mode 0600, atomic replace, other remotes
kept), refuses to replace one without `--force`, runs `rclone config reconnect` and
reports only non-secret facts. Doctor and probe offer it when the remote is missing.

Checked here (macOS 26.1, Python 3.9.6 and 3.12):
- Python: 18 tests in `worker/` and 130 in `tests/`; the publication check; `swift test`
  in `ios/CapturaCore` (462 tests, unchanged code).
- With fake `op`, `security` and `rclone` on PATH that log their arguments and
  environment: the secret never reaches a child's argv or environment, stdout, stderr or
  an error; the config file is 0600 in a 0700 folder; overwrite refusal and `--force`;
  `--field-map`; Keychain and `env:` references; missing or signed-out `op`; missing
  item, field or Keychain entry; malformed values refused without echoing them; failed
  sign-in; encrypted rclone configs left alone; `configure.py --from` validated like the
  flags, with explicit flags winning.

Not verified: the real 1Password CLI against a real item (its error texts are matched by
phrase, so an unrecognized one falls back to a generic message), the real Keychain, and a
real `rclone config reconnect` sign-in with a Desktop client, including which questions
rclone asks first.
