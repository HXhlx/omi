// src/renderer/src/components/insight/InsightToast.tsx
// Rendered inside the shared acrylic toast window (#/insight-toast). Shows
// whichever payload arrived last: a proactive insight ('insight:payload') or a
// meeting-detection notice ('meeting:toast' — Phase 5). Main owns visibility +
// auto-dismiss; hover pause reuses the same IPC for both kinds.
import { useEffect, useState } from 'react'
import type { InsightPayload, MeetingToastPayload, WhatsNewPayload } from '../../../../shared/types'
import { t } from '../../lib/i18n'
import './insight-toast.css'

type ToastContent =
  | { type: 'insight'; p: InsightPayload }
  | { type: 'meeting'; p: MeetingToastPayload }
  | { type: 'whatsnew'; p: WhatsNewPayload }

// Post-update changelog card (Phase 8). Shares the acrylic card shell; a compact
// list of the version's changes with the full notes one click away.
function WhatsNewCard({ p }: { p: WhatsNewPayload }): React.JSX.Element {
  return (
    <div
      className="insight-card"
      onMouseEnter={() => window.omi.insightHoverStart()}
      onMouseLeave={() => window.omi.insightHoverEnd()}
    >
      <div className="insight-head">
        <span className="insight-cat">{t("What's new", '最新动态')}</span>
        <button
          className="insight-x"
          onClick={() => window.omi.insightDismiss()}
          aria-label={t('Dismiss', '关闭')}
        >
          ✕
        </button>
      </div>
      <div className="insight-headline">
        {t(`New in Omi ${p.version}`, `Omi ${p.version} 更新内容`)}
      </div>
      <ul className="whatsnew-list">
        {p.changes.slice(0, 3).map((c, i) => (
          <li key={i}>{c}</li>
        ))}
      </ul>
      <div className="whatsnew-actions">
        <button
          className="meeting-btn meeting-btn-primary"
          onClick={() => window.omi.whatsNewOpenNotes()}
        >
          {t('View release notes', '查看更新说明')}
        </button>
      </div>
    </div>
  )
}

function MeetingCard({ p }: { p: MeetingToastPayload }): React.JSX.Element {
  const capturing = p.kind === 'capturing'
  const starting = p.kind === 'starting'
  const failed = p.kind === 'error'
  const errorKind = p.errorKind ?? 'startup'
  return (
    <div
      className="insight-card"
      onMouseEnter={() => window.omi.insightHoverStart()}
      onMouseLeave={() => window.omi.insightHoverEnd()}
    >
      <div className="insight-head">
        <span className="insight-cat">{t('Meeting detected', '检测到会议')}</span>
        <button
          className="insight-x"
          onClick={() => window.omi.meetingAction(p.meetingId, 'dismiss')}
          aria-label={t('Dismiss', '关闭')}
        >
          ✕
        </button>
      </div>
      <div className="insight-headline">
        {capturing
          ? t(`Omi is capturing — ${p.appName}`, `Omi 正在捕获 — ${p.appName}`)
          : starting
            ? t(`Starting capture — ${p.appName}`, `正在启动捕获 — ${p.appName}`)
            : failed
              ? errorKind === 'runtime'
                ? t(`Capture stopped — ${p.appName}`, `捕获已停止 — ${p.appName}`)
                : errorKind === 'save'
                  ? t(`Capture couldn't be saved — ${p.appName}`, `捕获无法保存 — ${p.appName}`)
                  : t(`Capture didn't start — ${p.appName}`, `捕获未能启动 — ${p.appName}`)
              : t(`${p.appName} looks like a meeting`, `${p.appName} 看起来是一场会议`)}
      </div>
      <div className="insight-advice">
        {capturing
          ? t('Audio is being transcribed into a conversation.', '音频正在转写为对话。')
          : starting
            ? t('Connecting audio and transcription…', '正在连接音频与转写…')
            : failed
              ? errorKind === 'save'
                ? t(
                    'The recording ended, but Omi could not save the local meeting transcript.',
                    '录音已结束，但 Omi 未能保存本地会议记录。'
                  )
                : t(
                    'Check your sign-in, internet connection, and Windows microphone access, then retry.',
                    '请检查登录状态、网络连接和 Windows 麦克风权限，然后重试。'
                  )
              : t('Capture and transcribe this meeting?', '要捕获并转写这场会议吗？')}
      </div>
      {p.firstRun ? (
        <div className="insight-foot">
          {t(
            'First run — change this in Settings → General.',
            '首次运行 — 可在“设置 → 通用”中更改。'
          )}
        </div>
      ) : null}
      <div className="meeting-actions">
        {capturing || starting ? (
          <button
            className="meeting-btn"
            onClick={() => window.omi.meetingAction(p.meetingId, 'stop')}
          >
            {starting ? t('Cancel', '取消') : t('Stop', '停止')}
          </button>
        ) : failed && errorKind === 'save' ? (
          <button
            className="meeting-btn"
            onClick={() => window.omi.meetingAction(p.meetingId, 'dismiss')}
          >
            {t('Dismiss', '关闭')}
          </button>
        ) : (
          <>
            <button
              className="meeting-btn meeting-btn-primary"
              onClick={() => window.omi.meetingAction(p.meetingId, 'start')}
            >
              {failed ? t('Retry', '重试') : t('Start capturing', '开始捕获')}
            </button>
            <button
              className="meeting-btn"
              onClick={() => window.omi.meetingAction(p.meetingId, 'dismiss')}
            >
              {t('Not now', '暂不')}
            </button>
          </>
        )}
      </div>
    </div>
  )
}

export function InsightToast(): React.JSX.Element {
  const [content, setContent] = useState<ToastContent | null>(null)

  useEffect(() => {
    document.body.classList.add('insight-toast-body')
    const offInsight = window.omi.onInsightShow((p) => setContent({ type: 'insight', p }))
    const offMeeting = window.omi.onMeetingToast((p) => setContent({ type: 'meeting', p }))
    const offWhatsNew = window.omi.onWhatsNewToast((p) => setContent({ type: 'whatsnew', p }))
    // Pull any pending payload: a push sent while this window was loading (meeting
    // detected — or the what's-new toast firing — right at startup) lands before
    // this effect subscribes and would otherwise be lost.
    void window.omi.meetingGetToast?.().then((p) => {
      if (p) setContent((cur) => cur ?? { type: 'meeting', p })
    })
    void window.omi.whatsNewGetPending?.().then((p) => {
      if (p) setContent((cur) => cur ?? { type: 'whatsnew', p })
    })
    return () => {
      document.body.classList.remove('insight-toast-body')
      offInsight()
      offMeeting()
      offWhatsNew()
    }
  }, [])

  if (!content) return <div className="insight-toast-body" />
  if (content.type === 'meeting') return <MeetingCard p={content.p} />
  if (content.type === 'whatsnew') return <WhatsNewCard p={content.p} />

  const insight = content.p
  return (
    <div
      className="insight-card"
      onMouseEnter={() => window.omi.insightHoverStart()}
      onMouseLeave={() => window.omi.insightHoverEnd()}
    >
      <div className="insight-head">
        <span className="insight-cat">{insight.category}</span>
        <button
          className="insight-x"
          onClick={() => window.omi.insightDismiss()}
          aria-label={t('Dismiss', '关闭')}
        >
          ✕
        </button>
      </div>
      <div className="insight-headline">{insight.headline}</div>
      <div className="insight-advice">{insight.advice}</div>
      <div className="insight-foot">{insight.sourceApp}</div>
    </div>
  )
}
