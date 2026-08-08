# What Was Said

Native, local-first macOS app for recording or importing meeting audio and turning it into diarized transcripts, structured notes, action items, and grounded recording chat.

Developed by Lars Heijnen.

Version 1.3.1 uses Apple's Liquid Glass APIs for the functional and navigation layer on macOS 26 or newer. Buttons, segmented navigation, pickers, the waveform scrubber, chat composer, recording controls, and speaker tools use native or grouped interactive glass. macOS 14–15 receive an equivalent system-material presentation with the same hierarchy, accessibility, and behavior.

The main window follows a focused two-column Mac pattern: destinations, smart views, folders, tags, and searchable recordings stay in the resizable sidebar while the selected recording gets the full workspace. Search covers transcript text, speakers, notes, action items, tags, and folders, and transcript results jump to their timestamp.

Audio and AI processing use the user's own OpenAI API account. Originals, transcripts, edits, chat history, and generated notes stay in the local managed library. No API key is stored in source, SwiftData, logs, or exports.

## Requirements

- macOS 14 or newer
- Apple silicon for the bundled release build
- Xcode 16 or newer; this workspace currently builds with `/Applications/Xcode-beta.app`
- An OpenAI API key with access to `gpt-4o-transcribe-diarize` and the selected Responses model

## Build and test

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift test
./Scripts/build_app.sh
./Scripts/create_dmg.sh
```

Open `Package.swift` in Xcode for development. The release scripts create:

- `Release/What Was Said.app`
- `Release/What-Was-Said-unsigned.dmg`

The app is ad-hoc signed only so sandbox entitlements work. It is not Developer ID signed or notarized. On another Mac, the recipient must right-click the app, choose **Open**, and confirm the Gatekeeper warning.

For a public release, set `DEVELOPER_ID_APPLICATION` and a `notarytool` Keychain profile named by `NOTARY_PROFILE`, then run `./Scripts/release_notarized.sh`. It builds with hardened runtime, submits the app and DMG to Apple, staples both tickets, runs Gatekeeper assessments, and prints the final SHA-256.

## First run

1. Review the local-first data flow in the three-step welcome screen.
2. Optionally add and validate an OpenAI API key there, or do it later in Settings. The key is saved in macOS Keychain.
3. Record a conversation, import one or more audio files, or restore a `.transcriptpipeline` package.
4. Confirm you are permitted to process each new recording, select a template, and choose **Process**.

Supported input extensions: `mp3`, `mp4`, `mpeg`, `mpga`, `m4a`, `wav`, and `webm`. Recordings may be up to three hours. AVFoundation must be able to decode large inputs for local compression and splitting; small supported OpenAI files can pass through unchanged if macOS cannot decode their codec.

## Live recording

Choose **Record** in the Library toolbar or press `⇧⌘R`:

- **Microphone** records the chosen Mac input for in-person conversations or a phone on speaker.
- **Mac app + microphone** uses Apple's ScreenCaptureKit picker. Select the Teams, Zoom, FaceTime, WhatsApp, or other app/window whose audio may be captured; the app records that audio together with your microphone.

Combined mode requires both tracks. While recording, the app confirms when Mac-app audio samples are arriving. If either the microphone or selected-app track is missing or unreadable, it shows an error and does not silently save an incomplete recording.

The first recording asks for macOS Microphone permission. For Mac-app audio, Apple’s system picker authorizes only the app or window selected for that capture session, so a separate full-screen grant is normally unnecessary. If macOS blocks either source, review What Was Said under **System Settings → Privacy & Security → Microphone** and **Screen & System Audio Recording**, then reopen the app.

Recording is local. Stopping creates a normal library item; nothing is uploaded until **Process** is clicked. A Mac app cannot tap a cellular call that exists only on an iPhone. Route the call through the Mac, use informed speakerphone recording, or export a recording made through an available iPhone feature and import it afterward.

## Data flow

1. The app copies an imported file into its managed Application Support library.
2. It locally converts audio to mono 16 kHz AAC near 32 kbps and splits near low-energy boundaries when necessary.
3. Audio parts go to `/v1/audio/transcriptions` with `gpt-4o-transcribe-diarize`.
4. Transcript text goes to `/v1/responses` for notes or chat. Every Responses request sets `store: false`.
5. Provider output is normalized into stable local SwiftData records. Model citations are accepted only when they match real transcript segment IDs.

No OpenAI Files, Conversations, Assistants, or vector-store APIs are used.

## Recovery and limits

- Each completed transcription part is checkpointed locally. Retry resumes from completed parts.
- Up to four clean first-part speaker clips are sent as known-speaker references for later parts.
- Speakers that cannot be matched safely remain separate and can be renamed or merged manually.
- Editing transcript text or speaker assignments marks existing analysis revisions as stale.
- Processing is queued one recording at a time, exposes per-part progress, can be cancelled, and resumes from completed checkpoints.
- Interrupted jobs are recovered as retryable on next launch rather than remaining stuck active.
- Cost figures are dated estimates. Stored token usage is authoritative.
- No realtime transcription, hidden/background auto-recording, cloud sync, accounts, or mind maps are included.

## Working with the library

- Generated notes are editable working documents. Action items can be edited, completed, assigned, dated, added, or removed, while every generated revision remains browsable.
- Recordings can be favorited and organized with a folder and tags. Smart views collect favorites, unprocessed recordings, stale notes, and failures.
- Multi-file import and **Process Visible** support batch workflows. The processing queue prevents a large import from flooding the API.
- **Ask Library** performs retrieval locally and sends only the top matching excerpts to OpenAI. Answers report how many excerpts were sent and link to exact source recordings and timestamps.
- Complete `.transcriptpipeline` packages preserve audio, transcript edits, speakers, notes revisions, chat, organization, and usage. Settings can export a full library backup; packages restore as new local copies without API keys.

## Playback and export

- The player includes an audio-derived waveform, direct scrubbing, ±10-second controls, playback speeds, and keyboard shortcuts.
- Transcript rows support in-recording search, native undo, speaker reassignment, restore-original, and deletion.
- Exports include Markdown, JSON, styled PDF, DOCX, SRT, WebVTT, Calendar/Tasks ICS, and a complete portable package. Notes and action items can also be copied directly.

## Responsiveness

- Audio playback observation is isolated to the player and transcript follower instead of redrawing the full detail page.
- Related Liquid Glass controls share effect containers; repeated transcript rows avoid per-row glass rendering to keep long lists smooth.
- Transcript order and timestamps are cached while open; playback uses binary search and scrolls only when the active segment changes.
- Library and transcript search are cached, debounced, and ranked away from the main actor; library-wide question retrieval is background-ranked too.
- Note drafts remain responsive while typing and are persisted after a short idle window instead of re-encoding and saving on every keystroke.
- Waveform peaks use a bounded sample budget away from the main actor and are cached in memory and beside the managed audio for instant reopening.
- Live-recording duration updates once per visible second.
- Keychain reads, writes, and validation run away from the main actor so macOS authorization cannot stall the interface.
- Transcription multipart bodies stream through private temporary files instead of duplicating a 24 MB audio chunk in memory.
- Normalized transcript data is stored once; restart checkpoints are deleted after successful processing rather than retaining a second raw response blob.

## Privacy

The app shows its data flow before import or recording and requires an authorization confirmation. Live recording never starts until the user chooses it, confirms permission, and selects the capture source. OpenAI data retention and regional controls remain properties of each user's OpenAI account and chosen API endpoint. Review current official documentation before using sensitive recordings:

- [OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data)
- [OpenAI file transcription](https://developers.openai.com/api/docs/guides/speech-to-text)

Use FileVault for local at-rest protection. Deleting a library item moves the app-managed recording directory to Trash and leaves the user's original import source untouched.
