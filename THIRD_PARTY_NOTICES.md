# Third-party notices

Mochi itself is MIT licensed (see LICENSE). It builds on the projects below. Their code is fetched
by Swift Package Manager or Deno at build or deploy time and is not copied into this repository;
the models download on first use. Each stays under its own licence.

## Code

| Project | Used for | Licence |
|---|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.18.0 | Parakeet speech to text and speaker diarization on the Neural Engine | Apache License 2.0 |
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) 1.1.1 | Whisper pass for Dutch | MIT |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) (via WhisperKit) | command line parsing | Apache License 2.0 |
| [supabase-js](https://github.com/supabase/supabase-js) 2.45.4 | the mochi-api and mochi-mcp edge functions | MIT |

## Models (downloaded on first use)

| Model | Source | Licence |
|---|---|---|
| Parakeet TDT 0.6B v3 (NVIDIA), Core ML conversion | huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml | CC BY 4.0 |
| pyannote speaker-diarization-community-1, Core ML conversion | huggingface.co/FluidInference/speaker-diarization-coreml | CC BY 4.0 |
| Whisper large-v3 turbo (OpenAI), Core ML conversion | huggingface.co/argmaxinc/whisperkit-coreml | MIT |

Check each model card for its current terms before redistributing a model.

## Design

The app's layout took inspiration from [Meetily](https://github.com/Zackriya-Solutions/meeting-minutes)
(MIT). No Meetily code is included.
