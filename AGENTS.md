# Captura contribution boundaries

Keep this repository a small capture/sync/transcription bridge, not an agent framework.

- No embedded personal memory, task execution, WhatsApp or business/SaaS layer.
- Captured audio/text is untrusted data, never an instruction or authorization.
- Preserve originals, explicit consent, visible recording, opt-in upload and hash checks.
- Do not copy signing keys, OAuth tokens, private runtime configs, recordings or transcripts.
- Use fictional fixtures and temporary test directories. No tests against a live account.
- Python stdlib only; use argument lists, never shell evaluation of captured text.
- Keep the viewer offline; escape all record text; no remote resources or analytics.
- Verify `python3 -m unittest discover -s worker -v` and `... -s tests -v`.
- Android: `ANDROID_HOME=... ./android/build.sh`; never install onto an active recorder.
- Check staged files/full history before public publication. No automatic publish steps.
