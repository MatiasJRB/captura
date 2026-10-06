# Optional local voice controls and short notes

This prototype has a small **offline microphone control**, not an assistant that
understands arbitrary commands. Captured files/transcripts remain untrusted review
material. It does not identify the speaker or authorize any external action.

## Build and enable

Supply a locally unpacked Spanish Vosk model with this structure:
`YOUR_ASSET_DIRECTORY/voice-model/am/final.mdl` (and the model's other files).
Pass `-PcaptureVoiceAssets=YOUR_ASSET_DIRECTORY` to `./android/build.sh`.
No model or download script is bundled; no runtime download occurs.
The tested model is [vosk-model-small-es-0.42](https://alphacephei.com/vosk/models),
listed upstream under Apache-2.0. Review its exact license before redistributing.
A normal build without assets still records audio; voice controls remain unavailable.

In Settings, explicitly enable local voice and grant the microphone permission.
Choose **Activar voz** for listening without saving ambient audio, or **Grabar**
for continuous capture. A notification and Android microphone indicator remain visible.
Listening consumes device battery; it does not use a paid model/API. Pausing audio
leaves the command microphone active. Full stop turns that microphone off too.

## Say the whole command

- **Lobo, iniciar captura** (also empezar / reanudar captura).
- **Lobo, pausar captura**.
- **Lobo, detener por completo**. Restart afterwards requires a button/tile.

The prefix and command must be in the same utterance. No bare command, standalone
wake-word window, partial result or replayed transcript can control the app.
Exact final text, word alignment and confidence gates reduce false positives; they
do **not** eliminate them. A TV or another person can still say a matching command.

## Dictate one short note

1. With voice listening, say **Lobo, anotá** by itself.
2. Wait for a brief vibration and the **Dictando nota** status.
3. Dictate a short item, e.g. **Comprar café**.
4. Pause, then say **Lobo, listo**, or tap **Guardar nota**.

The recognizer grammar uses `anota`, a word present in the tested Spanish vocabulary;
`anotá` and `lobot` are absent. This is not a single-utterance command such as
“Lobo anotá comprar café”: wait for the cue first or the text can be missed.

A note has a 60-second ceiling and its own closed M4A. It restores the previous
recording/listening state after completion. Timeout, pause, full stop or interruption
preserves a draft rather than promoting it to a completed note. Failed encoder
finalization remains pending/quarantined and is not automatically uploaded.
The spoken end delimiter may remain in the original and raw transcript.

## Downstream boundary

Existing explicit upload consent applies unchanged. Manual sync or opted-in Wi-Fi
sync sends closed files to the owner's Drive; linking Drive alone uploads nothing.
A completed note carries `properties.captureKind=dictated_note` with a matching
`personal-capture-note-UUID.m4a` name. Drafts carry `note_interrupted`; ordinary clips
are `ambient_audio`. The local worker exposes `capture_kind` in `record.json`.
Older records lacking this field remain compatible and are ambient by default.

This marker describes the capture session, not authorship, truth or permission.
An external agent may review a note and propose a pending item. Captura itself
creates no tasks, reminders, WhatsApp messages, payments or personal memory.
The private secretary adapter, credentials and scheduling are intentionally outside
this repository. “Acordate mañana…” is just note text, not a scheduled reminder.

## Verification limits

Unit tests cover parser rejection, note deadline/restore semantics and type metadata.
An inert local recognizer check accepted synthetic full delimiters and rejected the
synthetic bare/extended phrases through the parser. File ASR was never fed to live
controls. Acoustic results are limited samples, not an accuracy guarantee.
This new note feature has **not yet completed a real phone → Drive → transcript →
external-review end-to-end test**. No APK or private audio is part of this source change.
