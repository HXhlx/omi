# Provider cards for the local backend

The local fork used to hardcode one upstream per service: `:4000/v1` (LiteLLM)
for chat, `:8200` for speech-to-text, `:8300` for TTS. This replaces those three
constants with provider cards: a card per channel, a model dropdown per service on
each card, and one route per service chosen from the activated cards.

The app is a thin client. It reads the catalog and settings over HTTP and writes
back what the user picks; the backend resolves every call through the same route
chain, so what the settings page shows is what a request actually uses.

## Cards

`tools/flutter_backend/lib/src/provider_catalog.dart` lists the channels:

| id | label | services | key |
|---|---|---|---|
| `local-stt` | 本地 STT (FunASR) | speech to text | none |
| `local-llm` | 本地 LLM (LiteLLM) | language model, image | none |
| `local-tts` | 本地 TTS (speaches) | text to speech | none |
| `edge` | Edge TTS | text to speech | none |
| `minimax` | MiniMax | stt, tts, llm, image | yes |
| `qwen` | 千问 Token Plan | stt, tts, realtime, video | yes |
| `unisound` | 云知声 | stt, tts | yes |
| `mimo` | MiMo | tts, llm, image | yes |
| `doubao` | 豆包 Agent Plan | stt, tts | yes |
| `siliconflow` | 硅基流动 | stt | yes |

Each channel carries `staticModels` — one list per service, newest first. A card
opens with every service it supports, each row a dropdown; the selected value is
the card's `selectedModels[service]`, and an empty selection means the first entry
of the sorted candidate list (newest stable release; previews are dropped when a
stable exists). Discovery over `/models` merges into that list and is never
required for the default to work.

A channel counts as **activated** when it needs no key (the local trio and Edge) or
has one stored. Keys live in the SQLite settings table under `provider_key:<id>`,
never in the settings JSON and never in an HTTP response.

## Routes

One route per service, each a primary card plus ordered fallbacks
(`provider_settings.dart` → `RouteChain`). The unified-channel section on the
settings page edits them and only lists activated cards for that service.

A fresh install routes speech to text → `local-stt`, text to speech → `local-tts`,
language model → `local-llm`. That is the previous single-channel behaviour, now
visible and editable instead of hardcoded.

Resolution (`provider_router.dart` → `ProviderRouter.resolve`) walks the chain,
skips a card that no longer supports the service or lost its key, and hands the
first usable one to the client. Unsupported protocols fall through to the next
card rather than sending a wrong body: only OpenAI-compatible chat, multipart
transcription and `/v1/audio/speech` are implemented today.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/v1/provider/catalog` | every channel with capabilities and static models |
| GET | `/v1/provider/settings` | cards + routes |
| PUT | `/v1/provider/settings` | save cards + routes |
| GET | `/v1/provider/active` | service → activated card ids (the unified picker) |
| PUT | `/v1/provider/key` | store a key; answers only `{activated: bool}` |
| POST | `/v1/provider/discover` | candidate models for one card + service |

`/v1/auto/model-pick` and `/v1/tts/voices` now report the routed channel instead of
the old constants.

## App

`app/lib/pages/settings/provider_cards_page.dart`, reachable from Settings →
Recording & Transcription → Provider cards. Expand a card to change each service's
model or paste its key; the unified-channel dropdowns below the cards pick the
provider per service.

## Tests

`tools/flutter_backend/test/provider_test.dart` covers catalog invariants, the
newest-first ordering, settings round-trip, resolution skipping unactivated cards,
and the HTTP surface. `app/test/unit/provider_settings_api_test.dart` pins the wire
contract the page depends on.

```bash
cd tools/flutter_backend && dart test
cd app && flutter test test/unit/provider_settings_api_test.dart
```
