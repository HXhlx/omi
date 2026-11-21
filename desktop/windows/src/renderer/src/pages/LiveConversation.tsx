import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Loader2, Check } from 'lucide-react'
import { PageHeader } from '../components/layout/PageHeader'
import { liveConversation, requestFinalize, type LiveStatus } from '../lib/liveConversation'
import { t } from '../lib/i18n'
import { LiveNotesPanel } from '../components/recording/LiveNotesPanel'
import type { TranscriptLine } from '../../../shared/types'

function statusLabel(status: LiveStatus): string {
  if (status === 'connecting') return t('Connecting…', '连接中…')
  if (status === 'live') return t('Listening', '聆听中')
  if (status === 'error') return t('Microphone unavailable', '麦克风不可用')
  return t('Idle', '空闲')
}

// Live in-progress transcript of the mic capture (the "New" view). It does not
// control segmentation — the backend decides when the conversation ends, at which
// point it appears (titled) in the Conversations list and this view clears.
//
// Session ownership: the mic session runs in the capture window. This view just
// reads the mirrored store (kept in sync by LiveMirrorHost). Opening it sends a
// 'live-view' active command so the capture window's ContinuousSessionHost starts
// a one-off session when continuousRecording is OFF (when it's ON, the always-on
// session is already running and the refcount is a no-op).
export function LiveConversation(): React.JSX.Element {
  const navigate = useNavigate()
  const [segments, setSegments] = useState<TranscriptLine[]>(liveConversation.getSegments())
  const [status, setStatus] = useState<LiveStatus>(liveConversation.getStatus())
  const [errorMsg, setErrorMsg] = useState<string | null>(liveConversation.getError())
  const [saved, setSaved] = useState<boolean>(liveConversation.isSaved())
  const [topic, setTopic] = useState(liveConversation.getSavedTopic())

  useEffect(() => {
    return liveConversation.subscribe(() => {
      setSegments([...liveConversation.getSegments()])
      setStatus(liveConversation.getStatus())
      setErrorMsg(liveConversation.getError())
      setSaved(liveConversation.isSaved())
      setTopic(liveConversation.getSavedTopic())
    })
  }, [])

  // Tell the capture window a live view is open so it runs a session even when
  // continuousRecording is off (refcounted there). Re-issue if the capture window
  // restarts while we're mounted.
  useEffect(() => {
    window.omi?.captureCommand?.({ type: 'live-view', active: true })
    const unsubRestart = window.omi?.onCaptureEvent?.((ev) => {
      if (ev.type === 'capture-window-restarted') {
        window.omi?.captureCommand?.({ type: 'live-view', active: true })
      }
    })
    return () => {
      unsubRestart?.()
      window.omi?.captureCommand?.({ type: 'live-view', active: false })
    }
  }, [])

  return (
    <div className="flex h-full flex-col">
      <PageHeader
        title={
          saved ? topic.title || t('Conversation', '对话') : t('Live conversation', '实时对话')
        }
        titleSlot={
          saved ? (
            <h1 className="truncate font-display text-2xl font-bold tracking-tight text-white">
              {topic.emoji && <span className="mr-1.5">{topic.emoji}</span>}
              {topic.title || (
                <span className="italic text-white/45">{t('loading…', '加载中…')}</span>
              )}
            </h1>
          ) : undefined
        }
        subtitle={statusLabel(status)}
        onBack={() => navigate('/conversations')}
        actions={
          <div className="flex items-center gap-2">
            <button
              onClick={() => requestFinalize()}
              disabled={segments.length === 0 || saved}
              className="btn-record flex items-center gap-2 disabled:opacity-40"
              title={t(
                'Finalize this conversation now instead of waiting for the silence boundary',
                '立即结束并保存这段对话，而不等待静音判定'
              )}
            >
              <Check className="h-4 w-4" />
              {t('Save now', '立即保存')}
            </button>
            <span className="badge flex items-center gap-1.5">
              <Loader2 className={`h-3 w-3 ${status === 'live' ? 'animate-spin' : ''}`} />
              {statusLabel(status)}
            </span>
          </div>
        }
      />
      {/* Two-column split (mirrors Mac's expanded-transcript view): live
          transcript LEFT, LiveNotes panel RIGHT. Stacks on narrow widths. */}
      <div className="flex-1 overflow-hidden px-6 py-6 lg:px-10 lg:py-8">
        <div className="mx-auto flex h-full max-w-6xl flex-col gap-4 lg:flex-row">
          <div className="surface-card flex min-w-0 flex-1 flex-col p-6">
            <div className="mb-4 flex items-center justify-between">
              <h2 className="section-label">{t('Transcript', '转写文本')}</h2>
            </div>
            <div className="min-h-0 flex-1 overflow-y-auto">
              {segments.length > 0 ? (
                <ul className="space-y-4">
                  {segments.map((s, i) => (
                    <li key={s.id ?? i} className="flex gap-3 animate-fade-in">
                      <span className="shrink-0 self-start rounded-full border border-white/15 bg-white/5 px-2.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-white/75">
                        {s.speaker || t('speaker', '说话人')}
                      </span>
                      <p className="min-w-0 flex-1 whitespace-pre-wrap text-sm leading-relaxed text-white/85">
                        {s.text}
                      </p>
                    </li>
                  ))}
                </ul>
              ) : (
                <p className="text-sm text-white/45">
                  {status === 'error'
                    ? t(
                        `Couldn't start listening: ${errorMsg || 'unknown error'}. If this is a permission issue, allow the mic in Windows Settings → Privacy → Microphone; otherwise it'll retry automatically.`,
                        `无法开始聆听：${errorMsg || '未知错误'}。如果是权限问题，请在 Windows 设置 → 隐私 → 麦克风中允许访问；否则会自动重试。`
                      )
                    : t(
                        'Listening… start speaking and your words will appear here. The finished conversation will show up in your list automatically.',
                        '正在聆听…开始说话，内容会显示在这里。对话结束后会自动出现在你的列表中。'
                      )}
                </p>
              )}
            </div>
          </div>
          <div className="lg:w-[22rem] lg:shrink-0">
            <LiveNotesPanel />
          </div>
        </div>
      </div>
    </div>
  )
}
