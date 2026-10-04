---
name: Captura local reader
description: Restrained dark offline reader for reviewing captured evidence.
colors:
  bg: "#111815"
  surface: "#1d2822"
  fg: "#e7ece8"
  muted: "#b8c5bf"
  accent: "#a1d6be"
  line: "#3b4b42"
  error: "#f3b8a4"
typography:
  headline:
    fontFamily: "system-ui, -apple-system, sans-serif"
    fontSize: "2.5rem"
    lineHeight: 1.15
    letterSpacing: "-0.025em"
  title:
    fontFamily: "system-ui, -apple-system, sans-serif"
    fontSize: "1.35rem"
  body:
    fontFamily: "system-ui, -apple-system, sans-serif"
    fontSize: "17px"
    lineHeight: 1.6
  intro:
    fontFamily: "system-ui, -apple-system, sans-serif"
    fontSize: "1.2rem"
  label:
    fontFamily: "system-ui, -apple-system, sans-serif"
    fontSize: "0.9rem"
  note:
    fontFamily: "system-ui, -apple-system, sans-serif"
    fontSize: "0.95rem"
  code:
    fontFamily: "ui-monospace, monospace"
    fontSize: "14px"
    lineHeight: 1.5
rounded:
  input: "8px"
spacing:
  compact: "8px"
  small: "12px"
  base: "16px"
  segment: "20px"
  group: "24px"
  record: "28px"
  section: "32px"
  disclosure: "36px"
components:
  search-input:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.fg}"
    typography: "{typography.body}"
    rounded: "{rounded.input}"
    padding: "12px 14px"
    width: "100%"
  record:
    textColor: "{colors.fg}"
    padding: "28px 0"
  record-mobile:
    textColor: "{colors.fg}"
    padding: "24px 0"
  segment-time:
    textColor: "{colors.muted}"
    typography: "{typography.label}"
  original-audio:
    width: "100%"
  disclosure-summary:
    textColor: "{colors.fg}"
---

# Design System: Captura

## Overview

**Creative North Star: "Local evidence reader"**

A restrained, dark, linear reader inherited from the capture interface. System typography, quiet green-neutral surfaces and readable evidence take precedence over presentation. This documents the implemented reader, not a new brand, landing page or validated commercial product.

The viewer is a generated offline HTML file. An original audio control, when available, comes before timed transcript segments; fictional records explicitly say they have no original audio. Local search, a persistent live count and a native disclosure support reading without introducing agent actions.

**Key Characteristics:**
- Dark from the document root, including native controls and empty/error states.
- One linear list; audio before text; relative segment times.
- System fonts, flat dividers and restrained accent use.
- Local record filtering with a persistent polite live count.
- No remote assets, animation, analytics or embedded agent actions.

Source of truth: `viewer/index.html` (tokens, styles and filter), with record markup from `worker/reader.py`. `PRODUCT.md` establishes the small evidence-review scope and neutral working identity. The native Android recorder is a separate surface: `android/res/values/styles.xml` inherits `Theme.Material.NoActionBar` with an explicitly dark theme, system sans and native widgets. Its neutral waveform launcher artwork lives in `android/res/drawable/ic_launcher_foreground.xml`; its light launcher background is separate from the dark app window. This document does not prescribe a web redesign of Android.

## Colors

The existing palette is dark green-neutral, with pale mint reserved for useful emphasis. Frontmatter values preserve the CSS custom-property names and are normative. The sidecar's synthesized tonal strips are inspection previews only; they are not runtime colors or an expanded palette.

### Primary
- **Quiet mint (`accent`)**: flow text, text selection, input caret, keyboard focus and disclosure hover. It is not a large promotional fill.

### Neutral
- **Deep green-black (`bg`)**: document background and inverse selection text.
- **Raised green-neutral (`surface`)**: input and inline code backgrounds.
- **Soft pale neutral (`fg`)**: primary readable text.
- **Muted sage-neutral (`muted`)**: explanatory copy, timestamps, placeholder, footer and input hover border.
- **Subtle structural green (`line`)**: header, record and disclosure dividers; default input border.

### Semantic
- **Soft warm error (`error`)**: invalid-record explanation, on the same dark page rather than a separate light alert.

**The Evidence First Rule.** Use contrast and the mint accent for reading and states, not to imply that a transcript is verified or actionable.

## Typography

**Body and headings:** system UI fonts; no downloads. **Code:** system monospace. There is no separate display font or fixed cross-platform typeface.

### Hierarchy
- **Headline**: the page title; its desktop settings are in frontmatter and its mobile size is `2rem`.
- **Title**: review heading and record identifier; identifiers wrap anywhere when needed.
- **Body**: transcript and explanation, with paragraph measure capped at `70ch`. Transcript whitespace is preserved and long text wraps.
- **Intro**: the opening purpose sentence, modestly larger than body.
- **Label**: search label, footer and timestamps; timestamps use tabular numerals.
- **Note**: fixture note and flow text; the flow reduces to label size on mobile.
- **Code**: short CLI references, with a subtle surface fill.

Heading weights remain native browser defaults; the disclosure summary explicitly uses weight `600`. No geometric type scale or custom font metrics are introduced.

## Layout

A single centered reading column has a border-box maximum width of `1040px`, desktop padding `52px 32px 72px`, and paragraph measure `70ch`. The header, review introduction, tools, record list, disclosure and footer remain in document order. There is no sidebar, navigation bar, card grid or modal.

The tools row places the count alongside a search block capped at `380px`. Record segments use a `130px` relative-time column and a flexible text column with a `20px` gap. Each record starts with an identifier, then native audio or an explicit no-original note, then the segment list. Native audio fills available width up to `680px`.

At `max-width:600px`, the page padding becomes `32px 20px 52px`; the tools stack, search fills its row, transcript times stack above text with a `4px` gap, and record vertical padding becomes `24px`. The flow wraps as inline text, not navigation. No alternate mobile information architecture exists.

## Elevation & Depth

The reader uses no shadows, gradients, blur or floating layers. A slightly lighter input/code surface and thin structural dividers provide depth. There are no cards elevated above the page; native audio appearance is browser-dependent. No transitions or animation are defined.

## Shapes

Forms are restrained: the search field is gently rounded using the input-radius token. Records and disclosures are unboxed, separated by `1px` lines, rather than rounded cards. The waveform launcher mark belongs only to Android identity assets, not reader decoration.

## Components

### Search and live count
A visible label precedes the local search input. It uses the surface/background tokens, a line border, muted placeholder and mint caret. Hover changes the border to muted; keyboard focus is a mint `2px` outline offset by `4px`. Search performs a case-insensitive substring match against each record's complete rendered text (including its identifier and timestamps), hiding whole records; it does not rank results, highlight matches or query a server.

The visible count remains in a persistent `role="status"`, `aria-live="polite"`, `aria-atomic="true"` paragraph. The no-match explanation appears only when a nonempty record collection filters to zero. Search does not regenerate the export or transcribe audio.

### Records and transcript segments
Flat records have a top divider and vertical padding. The relative start/end times are muted, tabular and separate from the transcript text. Text is escaped by the generator, never rendered as arbitrary captured HTML. A model output with no segments gets a readable review-original explanation; it is not represented as guaranteed silence.

### Original audio
Use browser-native `<audio controls preload="metadata">` with the accessible label “Audio original”, dark color scheme and a bottom margin of `24px`. Its transport controls are not re-skinned or specified pixel-for-pixel. An export with an original copies a local media file; a fictional fixture instead shows the no-original note. The shared fictional demo has no audio, so it does not demonstrate playback.

### Scope disclosure
Native `<details>` and `<summary>` reveal boundaries beneath the records. The container uses the line token and disclosure spacing; the summary has a minimum height of `44px`, pointer cursor, semibold text, mint hover and the same keyboard-focus treatment as search. Its disclosure marker remains browser-native. Inline code uses the surface token; there is no CTA or agent action.

### Empty and error states
The no-records and no-matches states are plain readable text with vertical space. Invalid records use warm error text; there is no error modal, skeleton, loading animation or toast. The export is static: new records require generation again.

## Do's and Don'ts

### Do:
- Do preserve the inherited dark root and system typography.
- Do place the native original-audio control before its transcript; retain the no-original note for fictional fixtures.
- Do retain relative time ranges and stack them above text on narrow screens.
- Do keep search local and the count in a persistent polite, atomic live region.
- Do keep empty/error explanations readable on the same dark background.
- Do use fictional text in shared examples and keep actual exports private.

### Don't:
- Don't introduce a marketing visual world, decorative imagery or remote assets.
- Don't replace native audio/disclosure controls with an invented component system.
- Don't add motion, analytics, an agent-action toolbar or command execution to this reader.
- Don't imply speaker identity, authorization, ASR accuracy or business validation through visual styling.
- Don't treat Android native widgets or its launcher icon as browser component tokens.
