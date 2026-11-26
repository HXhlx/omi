# flutter_backend

Local Dart reimplementation of the Omi Python backend. It serves the same
HTTP/WebSocket wire contract the Omi desktop and mobile apps already speak, so
both native clients run unchanged against `http://127.0.0.1:8100` (main API)
and `http://127.0.0.1:8110` (desktop API, same process).

## Run

```bash
dart pub get
dart run bin/server.dart
```

Environment:

| Var | Default | Meaning |
|---|---|---|
| `FLUTTER_BACKEND_PORT` | `8100` | Listen port (bind 127.0.0.1) |
| `FLUTTER_BACKEND_DB` | `.flutter-backend/omi_local.db` | SQLite file |

No Firebase, GCS, Typesense, Stripe, Redis or Cloud Tasks. Identity is a single
local user (`local-dev-user`): any `Authorization: Bearer …` maps to it.

## Upstream workers

Inference and audio stay in purpose-built local processes; this server adapts
their contracts:

| Dependency | Default | Contract |
|---|---|---|
| LLM | `http://127.0.0.1:4000/v1` | OpenAI `/chat/completions` (LiteLLM → deepseek-flash) |
| STT | `http://127.0.0.1:8200` | `POST /v1/transcribe` (multipart `file=`) → `{text, segments, detected_language}` |
| TTS | `http://127.0.0.1:8300` | OpenAI `/v1/audio/speech` → MP3 (speaches/piper) |

When a worker is absent the corresponding route degrades to a documented
status (STT/TTS 503; embeddings stubbed at 1024 dims) instead of crashing.

Those three URLs are defaults, not the only option: provider cards let the app
pick a different channel and model per service, and every call resolves through
that route. See [PROVIDER_CARDS.md](PROVIDER_CARDS.md).

## Surface

- **conversations**: list/get/create-from-segments/delete/finalize/reprocess/
  title/visibility/starred/count/live/search/segments — with an in-process
  pipeline on `finalize` (LLM notes + memory extraction + action-item
  derivation, replacing the Cloud Tasks sweeper).
- **chat**: `v2/chat/completions` (desktop, non-stream + SSE),
  `v2/messages` (Omi SSE grammar `data:`/`message:`/`done:`),
  `v2/chat-sessions`, `v2/desktop/messages`, `v2/initial-message`, files.
- **memory**: `v3/memories` CRUD/batch, `memory/search`, `memory/vector/search`,
  `v1/memories/extract`, review queue, ledger.
- **tasks**: `v1/action-items` CRUD + completed toggle + batch/share/search;
  `v1/goals` (+ `/all`, canonical, progress, advice); `v1/folders`.
- **users**: profile, ai-profile, people, daily summaries (built from that day's
  conversations), preferences, export, flags (empty).
- **speech**: `v1/stt/transcribe`, `v2/voice-message/transcribe`,
  `v1/tts/voices`, `v1/users/voice`, `v2|v1/tts/synthesize`.
- **live**: WebSocket `v4/listen` + `v4/web/listen` (PCM batching → local STT,
  Omi segment-array and finalization frames), `v2/voice-message/transcribe-stream`.
- **desktop glue**: `v2/realtime/session` (inert mint), `v1/proxy/gemini/*`
  (generateContent via LLM, embeddings stubbed), `v2/desktop/prompts`,
  `v1/users/me/{subscription,usage-quota,trial}`, `v1/auto/model-pick`.
- **sync**: `v2/sync-capture-manifest`, `v2/sync-capture-end`,
  `v2/sync-local-files` (ledgered in `sync_ledger`).
- **long tail**: announcements, firmware, episodes, review, entities, screen
  activity, integrations, calendar, imports, workstreams, wrapped, csat, jit,
  dev API, MCP, billing (local no-op), phone, task integrations — each returns a
  well-formed payload, never a bare 404 for a route a released client calls.

Unknown paths still return FastAPI-shaped `{"detail": "Not Found"}` 404s.

## Layout

```
bin/server.dart            entry point (shelf + websocket handlers)
lib/src/db.dart            SQLite schema + LocalDb
lib/src/router.dart        Api: primary routes, WS, dispatch, SSE
lib/src/extra_routes.dart  ExtraRoutes: long-tail surface + fallbacks
lib/src/{conversation,store}.dart      Conversation model + persistence
lib/src/{knowledge,user_store,chat,pipeline}.dart  domain stores + v3 pipeline
lib/src/{llm,stt,tts}_client.dart      upstream workers
lib/src/tts.dart           voice catalog + preference shape
test/                      route + store tests (dart test)
```

## Verify

```bash
dart analyze        # clean
dart test           # 59 tests
```

## Not ported

Payments/Stripe, referrals, subscription enforcement, cloud admin/scheduler
sweeps, Google Calendar/X OAuth, Neo4j knowledge-graph rebuild, Twilio calls,
marketplace network — each has a local no-op or empty payload instead.
