// The Gemini vision call. The FIRST image Omi-on-Windows has ever sent to a
// model — both existing Gemini callers (screenSynthesis, insightEngine) are
// text-only.
//
// It goes through the Rust desktop backend's proxy, never Gemini directly: the
// API key lives on the server and never touches the device. The proxy's body cap
// is 5 MB and its own comment sizes it for "base64 JPEG + prompt" — the image
// path is the designed use, not a workaround.
//
// Same transport shape as aiUserProfile/service.ts: Electron `net.fetch`
// (Chromium's stack — proxy- and TLS-aware, unlike bare node fetch), the shared
// relayed session for the bearer token, and a timeout + session-abort wrapper.
import { net } from 'electron'
import { getAbortSignal, type BackendSession } from '../core/session'
import { GeminiLane } from '../../../shared/geminiAttribution'
import { geminiClientPlatform, geminiProxyFetch } from '../../../shared/geminiProxy'
import { FOCUS_RESPONSE_SCHEMA, parseScreenAnalysis, type ScreenAnalysis } from './models'

// Focus stays on the PT model: small payloads, and the lane earns its cost
// (CTR 1.275%, one of the best) — see modelPins.test.ts for the reservation ratchet.
export const MODEL = 'gemini-2.5-flash'
const REQUEST_TIMEOUT_MS = 30_000
/** 3 attempts total. Mac's backoff, exactly: 2s then 8s. */
const RETRY_DELAYS_MS = [2_000, 8_000]

// LOCAL ADAPT (XiaoWo): upstream's field contract lives ONLY in Gemini's
// generationConfig.responseSchema — the prompt text never names app_or_site or
// description. Restate the keys in prose so a provider that ignores (or drops)
// json_schema still fills every field instead of returning "Focused on :".
const FOCUS_FIELD_CONTRACT =
  '\n\nRespond with ONLY a JSON object using EXACTLY these keys: {"status": "focused" or "distracted", "app_or_site": "<the app or website visible in the main window>", "description": "<one-line description of what is on screen>", "message": "<coaching line>"}. Never leave app_or_site or description empty.'

/** Carries typed response metadata only — never a response body (it can echo the prompt,
 *  which carries the user's profile and window contents). */
export class GeminiHttpError extends Error {
  constructor(
    readonly status: number,
    readonly retryable: boolean
  ) {
    super(`gemini proxy HTTP ${status}`)
    this.name = 'GeminiHttpError'
  }
}

/** Replay only when the backend explicitly marks the response retryable. */
function isTransient(e: unknown): boolean {
  // The proxy owns replay safety. Only retry an outcome it explicitly marks as
  // safe; local timeouts and ambiguous transport failures may already have
  // reached the provider.
  return e instanceof GeminiHttpError && e.retryable
}

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(new DOMException('aborted', 'AbortError'))
    const t = setTimeout(resolve, ms)
    signal?.addEventListener(
      'abort',
      () => {
        clearTimeout(t)
        reject(new DOMException('aborted', 'AbortError'))
      },
      { once: true }
    )
  })
}

/** Run `fn` with a per-request timeout, composed with an optional external
 *  (session) abort signal. The two abort sources are made DISTINGUISHABLE: a
 *  timeout surfaces as a terminal 'TimeoutError', while the external signal
 *  surfaces as an 'AbortError' (a session sign-out — terminal). `fn` sees a single
 *  composed signal and doesn't care which fired. */
async function withTimeout<T>(
  ms: number,
  fn: (signal: AbortSignal) => Promise<T>,
  external?: AbortSignal
): Promise<T> {
  const ctrl = new AbortController()
  let timedOut = false
  const onAbort = (): void => ctrl.abort(external?.reason)
  const timer = setTimeout(() => {
    timedOut = true
    ctrl.abort(new DOMException('request timed out', 'TimeoutError'))
  }, ms)
  if (external?.aborted) ctrl.abort(external.reason)
  else external?.addEventListener('abort', onAbort, { once: true })
  try {
    return await fn(ctrl.signal)
  } catch (e) {
    // Whatever net.fetch rejected with, classify by WHICH source aborted us: our
    // own timer → TimeoutError (retryable); anything else (incl. the external
    // session signal) propagates unchanged so a sign-out stays an AbortError.
    if (timedOut) throw new DOMException('request timed out', 'TimeoutError')
    throw e
  } finally {
    clearTimeout(timer)
    external?.removeEventListener('abort', onAbort)
  }
}

/** The text of the first candidate's first text part, '' if the model returned
 *  nothing usable (a safety block, an empty candidate list). */
function extractText(json: unknown): string {
  const parts = (
    json as {
      candidates?: { content?: { parts?: { text?: string }[] } }[]
    }
  )?.candidates?.[0]?.content?.parts
  if (!Array.isArray(parts)) return ''
  return parts
    .map((p) => p.text ?? '')
    .join('')
    .trim()
}

async function attempt(
  session: BackendSession,
  systemPrompt: string,
  prompt: string,
  imageBase64: string,
  external?: AbortSignal
): Promise<string> {
  // LOCAL ADAPT (XiaoWo): vision rides the local OpenAI-compatible lane when
  // configured (VITE_OMI_LOCAL_VISION_BASE / _MODEL) — the Gemini proxy's
  // generateContent has no working route on the local gateway. Same image,
  // same prompts, same JSON contract; only the wire format changes.
  const visionBase = String(import.meta.env.VITE_OMI_LOCAL_VISION_BASE || '').trim().replace(/\/+$/, '')
  if (visionBase && import.meta.env.MODE !== 'test') {
    return withTimeout(
      REQUEST_TIMEOUT_MS,
      async (signal) => {
        const model = String(import.meta.env.VITE_OMI_LOCAL_VISION_MODEL || 'glm-5.3-flash')
        const res = await net.fetch(`${visionBase}/v1/chat/completions`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: localVisionAuth(session)
          },
          signal,
          body: JSON.stringify({
            model,
            messages: [
              { role: 'system', content: systemPrompt },
              {
                role: 'user',
                content: [
                  { type: 'text', text: `${prompt}${FOCUS_FIELD_CONTRACT}` },
                  { type: 'image_url', image_url: { url: `data:image/jpeg;base64,${imageBase64}` } }
                ]
              }
            ],
            // LOCAL ADAPT (XiaoWo): enforce the field contract at the provider.
            // Upstream gets this for free from Gemini's responseSchema; plain
            // json_object only promises "valid JSON" and glm-5.3-flash came back
            // with status+message but EMPTY app_or_site/description — the origin
            // of the "Focused on :" memories. json_schema (strict) is honored by
            // LiteLLM → glm-5.3-flash (probed live 2026-11-23, all fields filled);
            // FOCUS_FIELD_CONTRACT above is the belt to this suspenders.
            response_format: {
              type: 'json_schema',
              json_schema: { name: 'screen_analysis', strict: true, schema: FOCUS_RESPONSE_SCHEMA }
            },
            max_tokens: 1024,
            stream: false
          })
        })
        if (!res.ok) throw new GeminiHttpError(res.status, res.status === 429 || res.status >= 500)
        const json = (await res.json()) as { choices?: { message?: { content?: string } }[] }
        return (json.choices?.[0]?.message?.content ?? '').trim()
      },
      external
    )
  }
  return withTimeout(
    REQUEST_TIMEOUT_MS,
    async (signal) => {
      const res = await geminiProxyFetch(net.fetch, {
        baseURL: session.desktopApiBase,
        model: MODEL,
        action: 'generateContent',
        token: session.token,
        lane: GeminiLane.focus,
        workload: 'extraction',
        platform: geminiClientPlatform(process.platform),
        signal,
        body: JSON.stringify({
          contents: [
            {
              role: 'user',
              parts: [
                { text: prompt },
                // The TRUE encoding. Mac hardcodes `image/webp` here whatever
                // the bytes actually are — a Mac bug we are not porting.
                { inlineData: { mimeType: 'image/jpeg', data: imageBase64 } }
              ]
            }
          ],
          systemInstruction: { parts: [{ text: systemPrompt }] },
          generationConfig: {
            responseMimeType: 'application/json',
            responseSchema: FOCUS_RESPONSE_SCHEMA,
            // Flash's minimum. The proxy defaults it to 1024 when absent, and
            // a focus verdict does not need a reasoning budget — it needs to
            // be cheap enough to run all day.
            thinkingConfig: { thinkingBudget: 0 }
          }
        })
      })
      if (!res.ok)
        throw new GeminiHttpError(res.status, res.headers?.get?.('x-omi-retryable') === 'true')
      return extractText(await res.json())
    },
    external
  )
}

// Same ADMIN_KEY impersonation convention as the embeddings lane: main's
// net.fetch bypasses the session webRequest rewrite, so build the header here.
function localVisionAuth(session: BackendSession): string {
  const adminKey = String(import.meta.env.VITE_OMI_ADMIN_KEY || '')
  if (!adminKey) return `Bearer ${session.token}`
  try {
    const payload = JSON.parse(Buffer.from(session.token.split('.')[1], 'base64').toString('utf8'))
    const uid = payload?.sub ?? payload?.user_id
    if (typeof uid === 'string' && uid) return `Bearer ${adminKey}${uid}`
  } catch {
    /* fall through */
  }
  return `Bearer ${session.token}`
}

/**
 * Judge one screenshot. Returns null when the model answered with something we
 * cannot parse (see models.ts) — that is "no verdict", not an error, and must
 * not trip the caller's error backoff.
 *
 * Throws on transport/HTTP failure after all attempts are spent.
 */
export async function analyzeScreenshot(
  session: BackendSession,
  systemPrompt: string,
  prompt: string,
  imageBase64: string
): Promise<ScreenAnalysis | null> {
  // The session's signal: a sign-out or token refresh kills the request in
  // flight instead of leaving it running for 30s with a dead token.
  const external = getAbortSignal()
  let lastError: unknown

  for (let i = 0; i <= RETRY_DELAYS_MS.length; i++) {
    try {
      const text = await attempt(session, systemPrompt, prompt, imageBase64, external)
      if (!text) return null
      return parseScreenAnalysis(text)
    } catch (e) {
      lastError = e
      if (i === RETRY_DELAYS_MS.length || !isTransient(e)) break
      await sleep(RETRY_DELAYS_MS[i], external)
    }
  }
  throw lastError
}
