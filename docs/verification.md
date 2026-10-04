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
