# Privacy and review boundaries

- Recording is explicit and visible. Record yourself or obtain informed consent
  from everyone involved. Do not use this as covert surveillance.
- Originals remain on the phone; Drive sync adds cloud copies only after opt-in.
  Local imports and derived text add copies on your computer. No automatic deletion.
- Foreground microphone notification / Android indicator stay visible. The recorder
  can hold a partial wake lock while actively recording; battery readings are local.
- Android and iPhone request `drive.file`. The desktop's rclone grant is independent and may
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
- Publishing transcripts is opt-in (`"publish": true`, off by default). Only then does
  the Mac copy each finished transcript, as text, into a Google Doc in one folder of the
  person's own Drive («Captura · transcripciones»), owned by the account and refused if
  shared. Audio is never uploaded again. Anyone or any assistant the person gives access
  to their Drive or to a single Doc can read that copy; Google's own terms apply to it.
  Deleting a Doc doesn't delete the record on the Mac, and the worker never deletes Docs.
  This needs a `drive.file` grant: the same desktop grant then can also create files.
- Viewer exports copy audio/text to a dedicated local folder; do not publish them.
  Agent read access depends on the agent's actual filesystem permissions, not this doc.
- Configuration, tokens, model files, build outputs and keys are git-ignored; exclusions
  are a safety net, not a replacement for inspecting every staged file and full history.

## iPhone

- Recording starts only from the app or the "Grabar con Captura" action, which opens
  the app first; iOS does not let it start the microphone from the background. While
  recording, the screen shows "Grabando" and iOS shows its microphone indicator.
- Recordings live in the app's Application Support folder with Data Protection
  (`completeUntilFirstUserAuthentication`) and are excluded from iCloud/iTunes backups.
  Captura never deletes them. Deleting the app deletes them, so only delete it after
  everything was uploaded and imported.
- Upload is opt-in: linking Google only creates the private folder, uploading nothing.
  Automatic Wi-Fi sync and the manual "Sincronizar ahora" (which may use mobile data
  for 30 minutes) each ask first. The app asks Google for `openid`, `email` and
  `drive.file` only, never shares or deletes Drive files, and can be limited to one
  Workspace domain.
- Google tokens and the key that seals resumable-upload addresses are in the Keychain,
  readable after the first unlock and bound to this device (`ThisDeviceOnly`): not
  synced to iCloud Keychain nor restored onto another phone. Updating the app from
  Xcode keeps them; on a fresh install (after deleting the app) Captura discards any
  Keychain leftovers, so you link Google again.
- No transcription, analytics or third-party SDK runs on the phone. In system logs only
  error domains and codes are public; file paths and error details are marked private,
  which iOS redacts.
- `ios/Config/Captura.local.xcconfig` holds identifiers (bundle ID, Apple team ID,
  Google iOS client ID), not secrets, and is git-ignored. The Mac's Desktop client
  secret and rclone token belong only in rclone's own config file, never in the repo.
