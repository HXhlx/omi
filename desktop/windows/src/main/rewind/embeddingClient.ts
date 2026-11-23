// Gemini embeddings, via Omi's desktop-backend proxy. Main-process twin of the
// renderer's `lib/geminiClient.ts` (same base URL, same Firebase Bearer auth —
// the backend injects the real Gemini key), and a faithful port of the macOS
// embedding client: `gemini-embedding-001`, RETRIEVAL_DOCUMENT for stored OCR
// text vs RETRIEVAL_QUERY for a search box, L2-normalized on the way out.
//
// This lives in main (not the renderer) because the indexer it feeds is a
// background job that must survive renderer navigation/reloads — same reason as
// `ipc/memoryCleanup.ts`. The Firebase token only exists in the renderer, so it
// is relayed in over IPC (see `embeddingService.configureRewindEmbedSession`).
import { net } from 'electron'
import {
  EMBED_DIM,
  EMBED_MODEL,
  LOCAL_EMBED_BASE,
  LOCAL_EMBED_ENABLED,
  l2Normalize
} from './embedVector'
import { GeminiLane } from '../../shared/geminiAttribution'
import {
  geminiClientPlatform,
  geminiProxyFetch,
  type GeminiProxyAction
} from '../../shared/geminiProxy'

/** Gemini task types. Asymmetric on purpose: a stored passage and a search query
 *  are embedded into the same space but with different intent, which measurably
 *  improves retrieval over using one type for both. */
export type EmbedTaskType = 'RETRIEVAL_DOCUMENT' | 'RETRIEVAL_QUERY'

/** Where to reach the proxy, and who is asking. Relayed from the renderer. */
export type EmbedSession = { desktopApiBase: string; token: string }

const REQUEST_TIMEOUT_MS = 30_000
const MAX_RETRIES = 2

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms))

type EmbeddingResponse = { embedding?: { values?: number[] } }
type BatchEmbeddingResponse = { embeddings?: { values?: number[] }[] }

/** Body of one `embedContent` request (also the element shape of a batch). */
function requestBody(text: string, taskType: EmbedTaskType): Record<string, unknown> {
  return {
    model: `models/${EMBED_MODEL}`,
    content: { parts: [{ text }] },
    taskType
  }
}

/** Validate + normalize one raw `values` array from the API. */
function toVector(values: number[] | undefined): Float32Array | null {
  if (!values || values.length !== EMBED_DIM) return null
  return l2Normalize(Float32Array.from(values))
}

/**
 * POST to the proxy with retries on 429/503 (the same policy as the renderer's
 * Gemini client). Errors are deliberately sanitized to a status code: the proxy
 * body can echo request content and auth material, and this text ends up in logs.
 */
async function post(
  session: EmbedSession,
  method: GeminiProxyAction,
  body: unknown
): Promise<Record<string, unknown>> {
  let lastError = ''
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    const ctrl = new AbortController()
    const timer = setTimeout(() => ctrl.abort(), REQUEST_TIMEOUT_MS)
    try {
      // Electron's net.fetch uses Chromium's network stack (proxy/TLS aware) —
      // the path the rest of the app's main-process HTTP already takes.
      const res = await geminiProxyFetch(net.fetch, {
        baseURL: session.desktopApiBase,
        model: EMBED_MODEL,
        action: method,
        token: session.token,
        lane: GeminiLane.embedding,
        workload: 'maintenance',
        platform: geminiClientPlatform(process.platform),
        signal: ctrl.signal,
        body: JSON.stringify(body)
      })
      if (res.ok) return (await res.json()) as Record<string, unknown>
      if (res.status === 429 || res.status === 503) {
        lastError = `status ${res.status}`
        // No point sleeping after the last attempt — we are about to throw.
        if (attempt < MAX_RETRIES) await sleep(400 * (attempt + 1))
        continue
      }
      throw new Error(`embedding proxy request failed (status ${res.status})`)
    } catch (e) {
      // A timeout/network drop is retryable; a thrown non-retryable status is not.
      if (e instanceof Error && e.message.startsWith('embedding proxy request failed')) throw e
      lastError = `network: ${(e as Error).message}`
      if (attempt === MAX_RETRIES) break
      await sleep(400 * (attempt + 1))
    } finally {
      clearTimeout(timer)
    }
  }
  throw new Error(`embedding proxy request failed after retries (${lastError})`)
}

/** Embed one text (used for search queries). Throws on failure. */
export async function embedOne(
  session: EmbedSession,
  text: string,
  taskType: EmbedTaskType
): Promise<Float32Array> {
  if (LOCAL_EMBED_ENABLED) {
    const [vec] = await localEmbedBatch(session, [text])
    if (!vec) throw new Error('local embeddings returned no usable vector')
    return vec
  }
  const json = (await post(
    session,
    'embedContent',
    requestBody(text, taskType)
  )) as EmbeddingResponse
  const vec = toVector(json.embedding?.values)
  if (!vec) throw new Error('embedding proxy returned no usable vector')
  return vec
}

/**
 * The provider's hard limit on one `batchEmbedContents` body. Verified live: 101
 * requests is a `400 INVALID_ARGUMENT` that fails the entire batch. Enforced here
 * as well as at the queue (`EMBED_BATCH_SIZE`) so no future caller can put an
 * over-limit body on the wire, whatever it thinks its batch size is.
 */
const MAX_BATCH_REQUESTS = 100

/**
 * Embed a batch of texts. Returns one entry per input, in order; an entry is null
 * when the API omitted it or returned a wrong-dimension vector, so one bad item
 * can't discard the whole batch. Throws only when a request itself fails.
 *
 * Chunked at the API's 100-request ceiling, sequentially — a caller with 250
 * texts gets 3 round trips, not one guaranteed 400.
 */
export async function embedBatch(
  session: EmbedSession,
  texts: string[],
  taskType: EmbedTaskType
): Promise<(Float32Array | null)[]> {
  if (texts.length === 0) return []
  if (LOCAL_EMBED_ENABLED) return localEmbedBatch(session, texts)
  const out: (Float32Array | null)[] = []
  for (let i = 0; i < texts.length; i += MAX_BATCH_REQUESTS) {
    const chunk = texts.slice(i, i + MAX_BATCH_REQUESTS)
    const json = (await post(session, 'batchEmbedContents', {
      requests: chunk.map((t) => requestBody(t, taskType))
    })) as BatchEmbeddingResponse
    const embeddings = json.embeddings ?? []
    for (let j = 0; j < chunk.length; j++) out.push(toVector(embeddings[j]?.values))
  }
  return out
}

// LOCAL ADAPT (XiaoWo): OpenAI-compatible /v1/embeddings lane. The local LiteLLM
// proxy accepts `input: string[]` natively (verified live: ordered `data[].index`,
// 1024-dim qwen3-embedding), so one round trip per chunk — same 100-item ceiling
// as the Gemini path. taskType is a Gemini retrieval hint with no OpenAI
// equivalent; qwen3-embedding is trained symmetric, so it is intentionally
// dropped. Auth rides the SAME relayed Firebase Bearer the Gemini path uses —
// main's onBeforeSendHeaders rewrite turns it into the harness admin form on
// allowlisted local hosts, so no new credential plumbing exists.
type OpenAIEmbeddingResponse = { data?: { index?: number; embedding?: number[] }[] }

// The local lane's Bearer: the harness admin-impersonation form when configured
// (same convention as the webRequest rewrite — but net.fetch from MAIN does not
// pass through the session's onBeforeSendHeaders hooks, so the rewrite must
// happen here). Falls back to the relayed Firebase token for a real deployment.
function localAuthHeader(session: EmbedSession): string {
  const adminKey = String(import.meta.env.VITE_OMI_ADMIN_KEY || '')
  if (!adminKey) return `Bearer ${session.token}`
  try {
    const payload = JSON.parse(Buffer.from(session.token.split('.')[1], 'base64').toString('utf8'))
    const uid = payload?.sub ?? payload?.user_id
    if (typeof uid === 'string' && uid) return `Bearer ${adminKey}${uid}`
  } catch {
    /* undecodable token — fall through to the raw Bearer */
  }
  return `Bearer ${session.token}`
}

async function localEmbedBatch(
  session: EmbedSession,
  texts: string[]
): Promise<(Float32Array | null)[]> {
  const out: (Float32Array | null)[] = []
  for (let i = 0; i < texts.length; i += MAX_BATCH_REQUESTS) {
    const chunk = texts.slice(i, i + MAX_BATCH_REQUESTS)
    let lastError = ''
    let json: OpenAIEmbeddingResponse | null = null
    for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
      const ctrl = new AbortController()
      const timer = setTimeout(() => ctrl.abort(), REQUEST_TIMEOUT_MS)
      try {
        const res = await net.fetch(`${LOCAL_EMBED_BASE}/v1/embeddings`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: localAuthHeader(session)
          },
          body: JSON.stringify({ model: EMBED_MODEL, input: chunk }),
          signal: ctrl.signal
        })
        if (res.ok) {
          json = (await res.json()) as OpenAIEmbeddingResponse
          break
        }
        if (res.status === 429 || res.status === 503) {
          lastError = `status ${res.status}`
          if (attempt < MAX_RETRIES) await sleep(400 * (attempt + 1))
          continue
        }
        throw new Error(`local embeddings request failed (status ${res.status})`)
      } catch (e) {
        if (e instanceof Error && e.message.startsWith('local embeddings request failed')) throw e
        lastError = `network: ${(e as Error).message}`
        if (attempt === MAX_RETRIES) break
        await sleep(400 * (attempt + 1))
      } finally {
        clearTimeout(timer)
      }
    }
    if (!json) throw new Error(`local embeddings request failed after retries (${lastError})`)
    // Re-order by the API's own index field — the OpenAI contract allows any
    // order — then validate dimensions per item (one bad item never kills the batch).
    const byIndex = new Map<number, number[]>()
    for (const [j, item] of (json.data ?? []).entries()) {
      if (item?.embedding) byIndex.set(item.index ?? j, item.embedding)
    }
    for (let j = 0; j < chunk.length; j++) out.push(toVector(byIndex.get(j)))
  }
  return out
}
