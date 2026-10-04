# Local worker (macOS reference)

Python 3.10+ standard library, ffmpeg, rclone, whisper.cpp `whisper-cli` with VAD support,
a multilingual Whisper GGML model and a compatible Silero VAD GGML model. Install
these independently; no binary/model/credential is bundled or downloaded by our scripts.
See [whisper.cpp](https://github.com/ggml-org/whisper.cpp#voice-activity-detection-vad).
Check your installed `whisper-cli --help` lists `--vad` and `--vad-model`.

1. Configure a separate rclone Drive remote with **your own** desktop OAuth client and
   account. Understand its scopes; a default rclone grant may be broader than this
   worker's GET operations. Android and desktop clients are separate and `drive.file`
   visibility is not automatically shared between arbitrary OAuth applications.
   Configure both against your intended project and test actual visibility. Consult
   [rclone Drive setup](https://rclone.org/drive/) and
   [Drive scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth).
2. Copy `examples/config.example.json` to a private directory outside the repo.
   Replace `expected_account`, `remote`, `rclone_config`, tool/model paths. `~` expands.
   `quota_project` is optional; use your own project only if authorized to charge its
   API quota. No code enables billing or modifies gcloud configuration.
3. `python3 bin/capture probe --config /your/private/config.json` checks the account
   and discovers/verifies a private capture folder. It does not download. An empty
   folder ID never imports; multiple folders require an explicit ID.
4. Pin the exact folder ID printed by probe, after checking the phone upload receipt.
   `python3 bin/capture run --config /your/private/config.json` downloads at most three
   files and transcribes at most one per execution. No service starts automatically.
5. Read via `capture list/read`; optionally `capture view` into a new private folder.

`status.json`, SQLite receipts, failures and verified originals are local. Same ID+hash
is not reprocessed; changes are rejected. After three failures an item is quarantined
for human inspection; other items can progress. Revoked auth/missing model are errors.
Empty but valid VAD-assisted output is saved as `no_speech_detected`, not retried forever.

The worker runs ffmpeg and Whisper in an isolated temporary directory; stale output
cannot count as success. Model instructions are never sent to a hosted API.
`record.json` is written last so readers see only completed items.

Optional scheduling is left to your OS/agent after you verify one manual run; the
prototype does not install launchd or continuously poll a model. The shell CLI is not
an audio upload server and opens no public port.
