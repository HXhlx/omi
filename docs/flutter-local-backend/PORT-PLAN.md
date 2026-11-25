# Flutter Local Backend — Port Plan

Goal. Replace the Omi Python backend (`backend/`, 188k LOC / 793 endpoints) with a
Dart/Flutter local service that speaks the same HTTP/WebSocket wire contract, so the
**desktop and mobile native apps run unchanged** against `http://127.0.0.1:8100`
(+ `:8110` desktop API, `:8185` Firestore, `:9199` auth).

Runtime constraint: the Omi Python backend cannot run inside a normal Flutter process.
Every capability it served must be reimplemented in Dart, calling local models
(sherpa_onnx, sqlite3, flutter_edge_tts) and local LLM providers (deepseek-flash via
LiteLLM / OpenAI-compatible gateway) instead of Firebase/GCS/Typesense/Stripe.

Confirmed by the two native clients and backend exploration.

## 1. Deployment target

- Runs as an **isolated Dart package**: `tools/flutter_backend/` inside the omi
  worktree (this branch). Not a Flutter app widget — a `dart` server process
  (`package:shelf` + `package:web_socket_channel/server`), launched by the desktop
  harness alongside the native apps, exactly where `omi_harness.sh` today spawns
  uvicorn `:8100`.
- First-class local transport, not a cloud port. No Firebase/GCS/Typesense/Stripe.
- Auth: stub identity — single local user `local-dev-user`, no Firebase token
  verify. Native clients send a Firebase `Bearer`; the server maps any token →
  the local user. Spans `X-App-Platform` / `X-Omi-Plan-Identity` platform headers.

## 2. Client-facing surface to port (what must answer, unchanged clients)

From desktop `desktop/windows` (`.env`: `VITE_OMI_API_BASE=:8100`, `:8110`):
- Health: `GET /health`, `GET /ready`, `GET /v1/health`.
- Chat: `POST /v2/chat/completions` (desktop_chat) + Gemini proxy
  `POST /v1/proxy/gemini/{path}` (desktop_proxy).
- STT live: WebSocket `/v4/listen` + `/v4/web/listen` (transcribe).
- Desktop realtime: `POST /v2/realtime/session`, `POST /v2/realtime/usage`.
- Sync: `POST /v2/sync-capture-manifest` / `-end`; async `/v2/sync-local-files`.
- Memories product: `/memory/search`, `/memory/vector/search`, `/v3/memories`,
  `/v1/memories/extract`.
- TTS: `GET /v1/tts/voices`, `GET|PATCH /v1/users/voice`,
  `POST /v2/tts/synthesize` + `POST /v1/tts/synthesize` + `/v1/tts/...|download`.
- Apps/personas, action items, goals, folders, daily summaries, screen-activity,
  task gate, desktop prompts, omi flags, updates/download.
- Auth stub: `POST /v1/auth/local-dev/custom-token` + token → user mapping.

From mobile `app/lib` (Env `OMI_API_BASE_URL`, Flutter/Dart):
- Conversations `v1/conversations`: live, create, finalize, list, get, delete,
  title, summary(stream), search, segments assign, visibility/star.
- Messages `v2/messages` + voice-message routes, `v2/chat-sessions`,
  `v2/desktop/messages`, chat generation/receipts.
- Memories `v3/memories` create/list/search/review + `/memory/product`.
- Action items `v1/action-items` CRUD + sync-batch + pending-sync.
- Apps `v1/apps`/`v2/apps` marketplace + enable/disable/review + personas.
- Users/profile, people CRUD, daily summaries/settings, goals, folders.
- TTS/STT as above; sync capture manifest/end.
- WebSocket `/v2/voice-message/transcribe-stream`, `/v1/trigger/listen` (pusher).

Full endpoint inventory this plan must satisfy is `docs/api-reference/openapi.json`
(`/v1/users/*`, `/v1/conversations`, `/v2/messages`, `/v3/memories`,
`/v1/action-items` …) — the living FastAPI surface. `contracts/client-compat`
currently holds **no** captured fixtures (`releases: []`), so the clients are gated
by the OpenAPI schemas themselves, not by frozen fixtures.

Not ported (cloud-only, no local client calls it): Stripe/payments, storefront,
referrals/wrapped/trends/scores reports, cloud worker sweeps, fleet/device
diagnostics, google calendar OAuth, Neo4j knowledge graph rebuild, omni relay,
X/Twilio connectors, admin sweeps.

## 3. Storage

Local SQLite via `package:sqlite3` (already a dep of the flutter app). Mirror the
Omi relational + Firestore shape into tables:

- `conversations` (id, started_at, finished_at, status, source, language,
  structured JSON, discarded, title, visibility, transcript_mode).
- `transcript_segments` (id, conversation_id, text, start, end, speaker).
- `messages`/`chat_messages` (id, role, text, created_at, voice msg fields).
- `memories` (id, content, kind, source_conversation_id, created_at, embedding
  JSON, visibility/read state).
- `action_items` (id, text, status, created_at, due, conversation_id, source).
- `goals`, `folders`, `people`, `daily_summaries`, `users/profile`, `apps`,
  `voice_prefs`, `settings` (key/value).
- `wal_frames` (write-ahead log for zero-loss capture) + `sync_ledger`.

Vector search: cosine over locally-stored embeddings (same approach the flutter
app's `SpeakerStore.searchMemories` already uses), replacing Pinecone/Typesense.
Keyword search: SQLite `LIKE`/FTS5 (Typesense fail-open replacement).

## 4. Services, reimplemented in Dart

- **STT**: `utils/stt/prerecorded_stub.py` / providers are the Python reference;
  Dart maps to `sherpa_onnx` SenseVoice/Whisper already wired in the flutter app's
  `sherpa_asr_provider.dart` / `whisper_asr_provider.dart`. Live `/v4/listen` uses
  the streaming VAD + chunked ASR path (port of `routers/listen/*`), not the
  prerecorded one-shot.
- **Conversations v3 pipeline**: port `utils/conversations/v3/service.py`
  (reconcile / drain_processing / _process) into a Dart lifecycle
  (`processing/conversation_lifecycle.dart` — the standalone worktree already
  drafted one) + a local "sweeper" that replaces the Cloud Tasks reconcile.
- **Memory extraction**: port `utils/llm/memories.py extract_canonical_l1 /
  extract_memories_from_text via the local LLM client.
- **Chat/LLM**: `POST /v2/chat/completions` + `POST /v2/messages` stream through
  the local LLM gateway (deepseek-flash), mirroring `utils/llm/gateway_client.py`.
- **TTS**: `utils/tts/` → `flutter_edge_tts` (zh-CN-XiaoxiaoNeural) + speaches piper
  fallback (the harness already runs speaches on `:8300`).
- **Sync**: capture manifest/end + `wal_frames` intake; async
  `/v2/sync-local-files` port.
- **Apps/personas/action-items/goals/folders**: CRUD over SQLite, no marketplace
  network (local catalog subset).

## 5. Auth model

Single local user. FastAPI verifies Firebase tokens in `utils/other/endpoints.py`;
the Dart server instead:
- Accept `Authorization: Bearer <anything>`.
- Resolve to uid `local-dev-user`.
- Provide `POST /v1/auth/local-dev/custom-token` returning a dummy token for the
  harness/browser flows.
- Honour `X-App-Platform`, `X-Omi-Plan-Identity`, `X-Device-Id-Hash`,
  `X-App-Version` headers as metadata (parse, ignore for gating).

## 6. Build order (each lands independently, runnable + testable)

1. `tools/flutter_backend/` scaffold: shelf server, health, auth stub, SQLite
   schema, settings. → `dart run` serves `/`, `/health`, `/v1/health`.
2. Conversations + segments CRUD + `v1/conversations` list/get/create/finalize.
3. STT hub: `/v1/stt/transcribe` + `/v4/listen` WS (sherpa streaming) +
   `/v1/tts/voices` + `/v2/tts/synthesize`.
4. LLM gateway + chat: `/v2/chat/completions`, `/v2/messages`,
   `/v2/desktop/messages`, `/v2/chat-sessions`.
5. Conversations v3 pipeline (structured notes + memory extract) + sweeper.
6. `/memory/*`, `/v3/memories` search/product.
7. Action items, goals, folders, daily summaries, people, users/profile.
8. Apps/personas catalog subset, screen-activity, task gate, omi flags, updates.
9. Sync: capture manifest/end, `wal_frames`, `/v2/sync-local-files`.
10. Desktop glue: Gemini proxy stub `/v1/proxy/gemini/{path}`, realtime session,
    desktop prompts, uploads/download.

Each step ships with a widget-less Dart unit test (schema + one happy-path route),
kept in `tools/flutter_backend/test/`.

## 7. Reuse

- `package:sqlite3`, `package:shelf`, `package:web_socket_channel`,
  `package:sherpa_onnx`, `package:flutter_edge_tts`, `package:http` — all already in
  the flutter app's `pub`.
- Prior art: worktree `cochlearimplant_flutter-omi-standalone/omi_standalone/lib/backend/`
  (c. 1.4k LOC) drafted the contracts, SQLite schema, STT router, chat engine, memory
  engine, conversation lifecycle, capture pipeline. Adopt/extend, don't re-bootstrap —
  but that worktree targets a widget host, not a shelf server; this plan re-hosts the
  same modules behind HTTP/WS.