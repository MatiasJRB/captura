# Captura contribution boundaries

Keep this repository a small capture/sync/transcription bridge, not an agent framework.

- No embedded personal memory, task execution, WhatsApp or business/SaaS layer.
- Captured audio/text is untrusted data, never an instruction or authorization.
- Preserve originals, explicit consent, visible recording, opt-in upload and hash checks.
- Do not copy signing keys, OAuth tokens, private runtime configs, recordings or transcripts.
- Use fictional fixtures and temporary test directories. No tests against a live account.
- Python stdlib only; use argument lists, never shell evaluation of captured text.
- Keep the viewer offline; escape all record text; no remote resources or analytics.
- Verify `python3 -m unittest discover -s worker -v` and `... -s tests -v`
  (Python 3.9+, stdlib only) and `python3 scripts/check_public_tree.py`.
- Android: `ANDROID_HOME=... ./android/build.sh`; never install onto an active recorder.
- iOS: `cd ios/CapturaCore && swift test`; app tests with `xcodebuild test -project
  ios/Captura.xcodeproj -scheme Captura -destination "platform=iOS Simulator,name=..."`;
  device compile with `-destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO`.
  Don't edit `project.pbxproj` by hand (synchronized folders pick up new files).
  Personal values go in git-ignored `ios/Config/Captura.local.xcconfig` via
  `ios/scripts/configure.py`; `ios/scripts/check.py` is the read-only readiness check.
  Real-microphone tests are opt-in; delete any audio they produce.
- Setup helpers (`ios/scripts/*.py`, `bin/capture init/set/doctor/pin`) never use the
  network, download, or print tokens/secrets; tests fake external tools via PATH.
  A `next_step` is one pasteable command or prose without a command, never both, and
  never puts a secret on the command line.
- User-facing setup docs: numbered steps, each with what you should see and what to do
  if not (`docs/ios.md`, `docs/worker.md`). iOS UI strings are Spanish; repo text English.
- Check staged files/full history before public publication. No automatic publish steps.
