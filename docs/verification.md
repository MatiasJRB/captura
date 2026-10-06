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
