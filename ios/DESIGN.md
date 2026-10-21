# Captura iOS overview

Native SwiftUI parity with the Android status-first overview. Dark from launch;
Geome7ric navy background `#07111F`, blue surface `#001E49`, cyan `#70C5FB`, green
confirmed success `#00EF91`, text `#F3F7FB`, muted `#A8B9CD`. System text styles,
Dynamic Type, SF Symbols, native alerts/sheets and safe areas remain authoritative.

The header contains Captura and a 48pt settings action. The live microphone state
and adjacent 56pt recording control dominate. The latest actual topic is the content
panel title, with quieter remaining lexical hints and one ASR excerpt. There is no
generic topic heading or action to reveal it. Without content, the panel collapses.
The 48pt next-quote control is explicit; no automatic carousel. Source details show
ASR limits, reference and offset. The date represents processing, not speech time.

Separate Drive/transcription rows expose current evidence without a recordings list.
Google connection, upload opt-in, manual-upload confirmation, folder ID and review
retry remain in Settings. Portrait stacks capture/content/processing; landscape
keeps capture and processing in two columns with content below. Longer content and
large fonts scroll rather than reducing touch targets. iOS has no Android offline
voice-command engine; the overview does not invent an Activate voice control.

`WorkerFeedback` reads the optional bounded local report in
`Application Support/Captura/Sync/transcription-status.json`. It checks source IDs,
hashes and committed states; absent evidence remains unknown. The Mac-to-real-iPhone
delivery transport is not implemented here. Synthetic simulator reports demonstrate
content; they are not proof of real-device synchronization or capture.

## Verification — 2026-10-10

- Core: 465 tests passed, including report provenance and unavailable-state cases.
- App: 252 tests passed with local simulator signing; six opt-in tests skipped.
  An initial unsigned run failed on Keychain access (`-34018`); the signed run passed.
- Simulator and unsigned device builds passed. Portrait, empty/content states and
  landscape were inspected on an iPhone 17 Pro Max simulator using fictional text.
- Android counterpart: public/private unit tests and builds passed. Version
  `1.8.1-direct-topic` was installed and the direct topic verified on the S25,
  with the microphone off. Latest-topic/source selection has Python regression tests.
- No real iPhone installation or automatic report delivery was verified.
