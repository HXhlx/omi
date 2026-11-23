// LOCAL ADAPT (XiaoWo): always-on wake-word mic tee, capture-window side.
//
// A dedicated lightweight mic graph (getUserMedia → 16k ScriptProcessor) whose
// ONLY job is teeing PCM to main's sherpa-onnx KWS spotter (`wake-pcm`). It is
// deliberately separate from pttGraph's warm graph and the continuous listen
// session: those come and go with holds/preferences, but voice summon must work
// whenever the app is running and the user is signed in — including during
// onboarding, before any hold ever happened.
//
// Privacy posture matches the Flutter WakeWordService: audio is spotted locally
// in main and discarded; nothing is stored or uploaded from this lane. The
// `wakeEnabled` preference (default ON) is the user's off switch, and main mutes
// the tee for a cooldown after each hit (`wake-mute`) so the assistant's own
// spoken reply can't re-trigger it.
import { useEffect, useRef, useState } from 'react'
import { auth, onAuthStateChanged } from '../lib/firebase'
import { getPreferences, onPreferencesChange } from '../lib/preferences'
import { acquireMicStream, floatTo16BitPCM, teardownAudioGraph } from '../lib/audio'

const SAMPLE_RATE = 16000
// ~256ms per tee frame at 16k — small enough for sub-second spotter latency,
// large enough that IPC overhead stays negligible (~4 frames/s).
const PROCESSOR_BUFFER = 4096

export function WakeMicHost(): null {
  const [enabled, setEnabled] = useState(() => getPreferences().wakeEnabled !== false)
  const [signedIn, setSignedIn] = useState(() => !!auth.currentUser)
  const mutedUntilRef = useRef(0)

  useEffect(() => onPreferencesChange((p) => setEnabled(p.wakeEnabled !== false)), [])
  useEffect(() => onAuthStateChanged(auth, (u) => setSignedIn(!!u)), [])

  // Main's post-hit cooldown command.
  useEffect(() => {
    return window.omi?.onCaptureCommand?.((cmd) => {
      if (cmd.type === 'wake-mute') mutedUntilRef.current = Date.now() + cmd.cooldownMs
    })
  }, [])

  const shouldRun = enabled && signedIn
  useEffect(() => {
    if (!shouldRun) return
    let cancelled = false
    let graph: { nodes: AudioNode[]; stream: MediaStream; ctx: AudioContext } | null = null

    const start = async (): Promise<void> => {
      try {
        const stream = await acquireMicStream()
        if (cancelled) {
          stream.getTracks().forEach((t) => t.stop())
          return
        }
        const ctx = new AudioContext({ sampleRate: SAMPLE_RATE })
        const source = ctx.createMediaStreamSource(stream)
        const processor = ctx.createScriptProcessor(PROCESSOR_BUFFER, 1, 1)
        processor.onaudioprocess = (e): void => {
          if (Date.now() < mutedUntilRef.current) return
          const i16 = floatTo16BitPCM(e.inputBuffer.getChannelData(0))
          // slice(): the processor's input buffer is reused; the IPC structured
          // clone needs a standalone ArrayBuffer.
          window.omi?.captureEmit({ type: 'wake-pcm', pcm: i16.slice().buffer })
        }
        source.connect(processor)
        processor.connect(ctx.destination)
        graph = { nodes: [source, processor], stream, ctx }
      } catch (e) {
        // Mic denied/unavailable: voice summon is off, chord + tray still work.
        console.warn('[wake-mic] mic unavailable:', (e as Error).message)
      }
    }
    void start()
    return () => {
      cancelled = true
      if (graph) teardownAudioGraph(graph)
    }
  }, [shouldRun])

  return null
}
