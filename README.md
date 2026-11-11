# Mochi

A meeting recorder for macOS 27. Native SwiftUI, local first, MIT licensed.

Mochi records both sides of a call as two separate tracks, transcribes them on this Mac, and keeps calls, transcripts, tasks and projects in one place. It never touches the call app's audio devices: no BlackHole or other virtual driver, and no change to the default input or output.

## How it records

- **The other side:** a Core Audio process tap on the call app only (Chrome, Zoom, FaceTime, WhatsApp, Teams and others), in a private aggregate device. It follows Chrome's audio helper as it comes and goes, follows the headset's real sample rate (AirPods drop to 24 or 16 kHz in call mode), and writes Bluetooth profile switches as silence so the track stays in step.
- **Your side:** a read-only IO proc on the exact input device the call app reads, next to the call app. No voice processing, no aggregate, no routing.
- Both tracks are 48 kHz WAV files in `~/Mochi/calls/<call id>/`, with start times so they line up.
- Recording stops when you stop it, or when the call app stops using audio (with a 60 second "Call ended? Still recording" prompt and Keep Recording). Never on a calendar end time.

## Transcription and summaries

- Live and after the call: Parakeet TDT v3 (FluidAudio, Neural Engine), English and Dutch.
- Dutch: a Whisper pass after the call on the parts that are Dutch.
- Summaries: optional, with Claude (`claude-opus-5-5`); the transcript text is the only thing sent. Paste your Anthropic API key in Settings; it is kept in the Keychain (service `mochi`, account `ANTHROPIC_API_KEY`). Set your name in Settings too, so summaries know which action items are yours.

## Build

Needs macOS 27 and Xcode with the macOS 27 SDK.

```bash
cp mochi.env.example mochi.env   # optional: bundle id, signing identity, Supabase project
./build.sh                       # build/Mochi.app
./build.sh --install             # also copies it to /Applications
swift test                       # MochiKit tests
```

Without a `mochi.env`, `build.sh` signs ad hoc and builds a local-only Mochi: recording, transcripts, summaries, tasks and projects all work, and sync, sign-in and updates stay off.

Set `MOCHI_SIGN_IDENTITY` to your own Apple Development identity (`security find-identity -v -p codesigning`) if you rebuild often: macOS ties the microphone and system audio recording permissions to the signature, so an ad-hoc build asks again after every rebuild.

Models download on first use: Parakeet TDT v3 and the speaker models (FluidAudio) and Whisper large-v3 turbo (WhisperKit), all from Hugging Face.

## Sync and the Claude connector (optional)

Mochi can keep a text-only copy of calls, summaries, tasks and projects in your own Supabase project (audio never leaves the Mac). That gives you sign-in with an emailed link, sync between your Macs and the iPhone app, a Claude connector (MCP) over your meetings and tasks, and in-app updates.

1. Create a Supabase project. Note its URL (`https://<ref>.supabase.co`) and its publishable key.
2. Apply the migrations and deploy the two functions with the Supabase CLI:
   ```bash
   supabase link --project-ref <ref>
   supabase db push
   supabase functions deploy mochi-api --no-verify-jwt
   supabase functions deploy mochi-mcp --no-verify-jwt
   ```
3. Set the function secrets. Only `MOCHI_OWNER_EMAIL` can sign in; the connector key is any long random string.
   ```bash
   supabase secrets set MOCHI_OWNER_EMAIL=you@example.com MOCHI_MCP_TOKEN=$(openssl rand -hex 32)
   ```
4. In Authentication, add yourself as a user with that email (Mochi never creates accounts), and add `mochi://auth` to the allowed redirect URLs.
5. Put the URL and publishable key in `mochi.env` (`MOCHI_SUPABASE_URL`, `MOCHI_SUPABASE_KEY`) and rebuild. Sign in under Settings, Account.
6. For the Claude connector, store the same `MOCHI_MCP_TOKEN` in the Keychain (`security add-generic-password -s mochi -a MOCHI_MCP_TOKEN -w <token>`), then use Copy URL and Copy Key in Settings and add a custom connector in claude.ai with an `x-api-key` header.

### Updates

`release.sh` builds, smoke-tests and uploads a release to the private `releases` bucket; every signed-in Mac offers it on Today within 6 hours. It needs a real signing identity, because a Mac only installs an update signed by the same team as the app it is running.

```bash
SUPABASE_PAT=... ./release.sh "What changed"
```

## iPhone app

`ios/` holds a small companion app (calls, tasks, upcoming meetings, and in-person recording transcribed on the phone). It needs the Supabase setup above. With [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
set -a; . ./mochi.env; set +a      # MOCHI_BUNDLE_ID, MOCHI_TEAM_ID, MOCHI_SUPABASE_URL, MOCHI_SUPABASE_KEY
cd ios && xcodegen && open MochiPhone.xcodeproj
```

## Layout

| Path | What |
|---|---|
| `Sources/MochiCapture` | two-track capture: process tap, mic recorder, call app detection |
| `Sources/MochiTranscribe` | Parakeet and Whisper engines, live captions |
| `Sources/MochiKit` | models, local storage, transcript text and cleanup |
| `Sources/Mochi` | the app: window, menu bar, recording pill, tasks, projects, settings |
| `Sources/mochi-transcribe` | command line test tool for the engines |

| `supabase` | database migrations and the mochi-api (sync) and mochi-mcp (Claude connector) functions |
| `ios` | the iPhone companion app |

## Privacy

Audio is recorded and kept only on the Mac (or the iPhone that recorded it). Transcription runs on device. Voiceprints for speaker names stay on the Mac and are never synced. Only when you turn them on, the transcript text goes to Claude for summaries, and a text copy goes to the Supabase project you set up.

Recording calls can need everyone's consent where you live. Tell people on the call that you are recording.

## Licence

MIT, see [LICENSE](LICENSE). Third-party code and models are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
