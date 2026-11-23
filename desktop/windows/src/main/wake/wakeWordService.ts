// LOCAL ADAPT (XiaoWo): always-on wake-word spotting for the desktop shell.
//
// The XiaoWo assistant is summoned by VOICE ("小蜗同学" / "小蜗助手"), not only
// the Shift+Space chord. The capture window's WakeMicHost tees raw 16k mono PCM
// here (`wake-pcm`); this service runs the SAME sherpa-onnx KWS zipformer model
// the Flutter app uses (models/kws in the repo root — pinyin modeling units, so
// new keywords are a text-file line, no retraining). A hit fires the bar's
// existing tray-summon path (peek pill, no PTT phases) and mutes the tee for a
// cooldown so the assistant's own voice can't re-trigger it.
//
// Fail-open by construction: a missing model dir / native addon logs once and
// leaves the chord + tray paths untouched. Nothing here gates app startup.
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { app } from 'electron'
import { onCaptureEventInMain } from '../ipc/captureBridge'
import { getCaptureWc } from '../captureWindow'
import { summonFromTray } from '../bar/window'

/** Repo-root KWS model dir (dev checkout layout). Packaged builds can point
 *  OMI_KWS_MODEL_DIR at a bundled copy; absent ⇒ the service stays inert. */
function defaultModelDir(): string {
  // Dev: app.getAppPath() is out/main (electron-vite), NOT the project root —
  // walk up until a models/kws dir appears (repo root carries it). Packaged:
  // resources/kws beside the asar (win-audio-helper convention).
  if (app.isPackaged) return join(process.resourcesPath, 'kws')
  let dir = app.getAppPath()
  for (let i = 0; i < 8; i++) {
    const candidate = join(dir, 'models', 'kws')
    if (existsSync(candidate)) return candidate
    const parent = join(dir, '..')
    if (parent === dir) break
    dir = parent
  }
  return join(app.getAppPath(), 'models', 'kws')
}

const COOLDOWN_MS = 2500
/** Matches the Flutter SherpaKeywordSpotter default (keyword_spotter.dart). */
const KEYWORDS_THRESHOLD = 0.25

type Spotter = {
  createStream: () => Stream
  isReady: (s: Stream) => boolean
  decode: (s: Stream) => void
  getResult: (s: Stream) => { keyword?: string }
  reset: (s: Stream) => void
}
type Stream = { acceptWaveform: (o: { samples: Float32Array; sampleRate: number }) => void }

let spotter: Spotter | null = null
let stream: Stream | null = null
let unsubscribe: (() => void) | null = null
let mutedUntil = 0
let lastHitAt = 0
let warned = false

function warnOnce(msg: string): void {
  if (warned) return
  warned = true
  console.warn(`[wake] ${msg}`)
}

/** Build the spotter from the model dir. Returns false (inert) on any failure. */
function init(): boolean {
  const modelDir = process.env.OMI_KWS_MODEL_DIR || defaultModelDir()
  const encoder = join(modelDir, 'encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx')
  const keywordsFile = join(modelDir, 'keywords.txt')
  if (!existsSync(encoder) || !existsSync(keywordsFile)) {
    warnOnce(`KWS model not found at ${modelDir} — voice summon disabled (chord still works)`)
    return false
  }
  try {
    // Lazy require: the native addon must never load (or fail) at module scope —
    // a missing win-x64 binary would take the whole main bundle down with it.
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const sherpa = require('sherpa-onnx-node') as {
      KeywordSpotter: new (config: unknown) => Spotter
    }
    spotter = new sherpa.KeywordSpotter({
      modelConfig: {
        transducer: {
          encoder,
          decoder: join(modelDir, 'decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx'),
          joiner: join(modelDir, 'joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx')
        },
        tokens: join(modelDir, 'tokens.txt'),
        numThreads: 1,
        provider: 'cpu',
        debug: 0
      },
      keywordsFile,
      keywordsThreshold: KEYWORDS_THRESHOLD
    })
    stream = spotter.createStream()
    console.log(`[wake] KWS ready (${modelDir})`)
    return true
  } catch (e) {
    warnOnce(`KWS init failed: ${(e as Error).message} — voice summon disabled`)
    spotter = null
    stream = null
    return false
  }
}

function onPcm(pcm: ArrayBuffer): void {
  if (!spotter || !stream) return
  const now = Date.now()
  if (now < mutedUntil) return
  const i16 = new Int16Array(pcm)
  const f32 = new Float32Array(i16.length)
  for (let i = 0; i < i16.length; i++) f32[i] = i16[i] / 32768
  stream.acceptWaveform({ samples: f32, sampleRate: 16000 })
  while (spotter.isReady(stream)) {
    spotter.decode(stream)
    const r = spotter.getResult(stream)
    if (r.keyword) {
      // Reset BEFORE acting so the same utterance can't double-fire while the
      // summon/mute IPC is in flight.
      spotter.reset(stream)
      if (now - lastHitAt < COOLDOWN_MS) return
      lastHitAt = now
      mutedUntil = now + COOLDOWN_MS
      console.log(`[wake] keyword hit: ${r.keyword}`)
      const wc = getCaptureWc()
      if (wc && !wc.isDestroyed()) {
        wc.send('omi-capture:cmd', { cmd: { type: 'wake-mute', cooldownMs: COOLDOWN_MS }, ownerId: wc.id })
      }
      // Same path as the tray's "唤出悬浮栏": peek when hidden, hide when open.
      // No PTT phases — the mic tee is not a physical hold.
      summonFromTray()
      return
    }
  }
}

/** Start the wake-word service. Idempotent; call once from main's startup. */
export function startWakeWordService(): void {
  if (unsubscribe) return
  if (!init()) return
  unsubscribe = onCaptureEventInMain((event) => {
    if (event.type === 'wake-pcm') onPcm(event.pcm)
  })
}

export function stopWakeWordService(): void {
  unsubscribe?.()
  unsubscribe = null
  spotter = null
  stream = null
}
