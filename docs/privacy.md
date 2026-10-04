# Privacy and review boundaries

- Recording is explicit and visible. Record yourself or obtain informed consent
  from everyone involved. Do not use this as covert surveillance.
- Originals remain on the phone; Drive sync adds cloud copies only after opt-in.
  Local imports and derived text add copies on your computer. No automatic deletion.
- Foreground microphone notification / Android indicator stay visible. The recorder
  can hold a partial wake lock while actively recording; battery readings are local.
- Android requests `drive.file`. The desktop's rclone grant is independent and may
  cover more files; restricting this worker to GET in one exact private folder does
  NOT turn that grant into a narrow OAuth permission. Configure a separate, least-
  privilege desktop authorization you understand. Do not reuse another person's token.
- Local Whisper/VAD uses CPU/GPU, disk and electricity, not a hosted model API. Cloud
  storage/network and any external agent's reasoning have separate costs.
- Text can be wrong or include other voices/media. VAD is not speaker identification,
  a guarantee of silence detection, or a sleep/health diagnosis.
- Every record is `review_only: true`. Audio/transcripts are untrusted inputs, never
  shell code, agent instructions or permission to send messages/create commitments.
- The worker checks account, folder ownership/sharing, ID, size and hashes; downloads
  are idempotent; repeated failures are quarantined. Revoked auth produces an error.
- Viewer exports copy audio/text to a dedicated local folder; do not publish them.
  Agent read access depends on the agent's actual filesystem permissions, not this doc.
- Configuration, tokens, model files, build outputs and keys are git-ignored; exclusions
  are a safety net, not a replacement for inspecting every staged file and full history.
