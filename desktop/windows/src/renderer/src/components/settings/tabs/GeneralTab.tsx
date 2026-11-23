import { useEffect, useState } from 'react'
import {
  LayoutDashboard,
  MessageSquarePlus,
  MessagesSquare,
  Mic,
  Monitor,
  Power,
  Presentation,
  ScanEye,
  Zap,
  Languages
} from 'lucide-react'
import type { MeetingMode, RewindSettings } from '../../../../../shared/types'
import { getPreferences, onPreferencesChange, setPreferences } from '../../../lib/preferences'
import { SettingRow } from '../SettingRow'
import { Toggle } from '../Toggle'
import { FontSizeCard } from '../FontSizeCard'
import { t } from '../../../lib/i18n'

export function GeneralTab(): React.JSX.Element {
  const [chatHistoryMode, setChatHistoryMode] = useState(getPreferences().chatHistoryMode)
  const [signLanguageEnabled, setSignLanguageEnabled] = useState(false)

  useEffect(() => {
    window.omi
      ?.signLanguageGetEnabled()
      .then(setSignLanguageEnabled)
      .catch(() => {})
  }, [])

  return (
    <>
      {/* macOS General leads with the capture-status cards (spec §3.1). */}
      <ScreenCaptureRow />
      <AudioRecordingRow />
      <ActionAutomationRow />
      <ScreenAnalysisRow />
      <SettingRow
        icon={MessagesSquare}
        title={t('Chat history', '聊天历史')}
        subtitle={t(
          'By default, one ongoing conversation (shared with the floating bar) that persists across launches — scroll up in chat to load older messages. Or start a fresh conversation each launch.',
          '默认是一条持续对话（与悬浮栏共享），跨启动保留 —— 在聊天中上滑加载更早消息。也可以每次启动新开对话。'
        )}
        keywords="conversation thread floating bar history infinite"
        control={
          <select
            value={chatHistoryMode}
            onChange={(e) => {
              const v = e.target.value as 'per-launch' | 'infinite'
              setChatHistoryMode(v)
              setPreferences({ chatHistoryMode: v })
            }}
            className="rounded-md bg-white/10 px-2 py-1.5 text-sm text-white focus:outline-none"
          >
            <option value="infinite" className="bg-neutral-900">
              {t('One ongoing conversation (default)', '一条持续对话（默认）')}
            </option>
            <option value="per-launch" className="bg-neutral-900">
              {t('New conversation each launch', '每次启动新开对话')}
            </option>
          </select>
        }
      />
      <SettingRow
        icon={Languages}
        title={t('Sign-language translation', '手语翻译')}
        subtitle={t(
          'Transcribe spoken text into sign-language poses via the sign.mt service. Disabled by default — all transcript text is sent to an external API, which requires explicit consent.',
          '通过 sign.mt 服务把语音文本转成手语姿态。默认关闭 —— 转写文本会发送到外部 API，需要明确同意。'
        )}
        keywords="sign language translation sign.mt consent privacy"
        control={
          <button
            onClick={async () => {
              const next = !signLanguageEnabled
              setSignLanguageEnabled(next)
              await window.omi?.signLanguageSetEnabled(next)
            }}
            className={`rounded-md px-3 py-1.5 text-sm font-medium transition-colors ${
              signLanguageEnabled
                ? 'bg-green-500/20 text-green-400 hover:bg-green-500/30'
                : 'bg-white/10 text-white/60 hover:bg-white/20'
            }`}
          >
            {signLanguageEnabled ? t('Enabled', '已开启') : t('Disabled', '已关闭')}
          </button>
        }
      />
      <MultiChatRow />
      <LegacyHomeRow />
      <MeetingDetectionRow />
      <LaunchAtLoginRow />
      <FontSizeCard />
    </>
  )
}

function ActionAutomationRow(): React.JSX.Element {
  const automationAvailable = window.omi.automationEnabled
  const [autoConsent, setAutoConsent] = useState<boolean>(!!getPreferences().automationConsentedAt)
  const toggleAutomation = (on: boolean): void => {
    setAutoConsent(on)
    setPreferences({ automationConsentedAt: on ? Date.now() : undefined })
  }

  return (
    <SettingRow
      icon={Zap}
      dot={automationAvailable && autoConsent ? 'on' : 'off'}
      title={t('Let Omi take actions', '让小蜗代操作')}
      subtitle={
        !automationAvailable
          ? t('Disabled in this build.', '此版本不可用。')
          : autoConsent
            ? t('Omi can click and type in your apps when you ask.', '你开口时，小蜗可以在你的应用里点击和输入。')
            : t('Turn on to let Omi act in your apps when you ask.', '开启后，你开口时小蜗可以在你的应用里代操作。')
      }
      keywords="automation actions desktop control agent take action flaui approve"
      control={
        <Toggle
          on={automationAvailable && autoConsent}
          onChange={toggleAutomation}
          disabled={!automationAvailable}
          label={t('Let Omi take actions', '让小蜗代操作')}
        />
      }
    />
  )
}

// Screen Capture status card (macOS General §3.1). Mirrors the Sidebar's "Screen
// recording" toggle: both bind to the persistent Rewind `captureEnabled` setting.
// We subscribe to the `rewind:settings` broadcast so flipping the switch in the
// Sidebar (or another window) live-updates this card without a refetch.
function ScreenCaptureRow(): React.JSX.Element {
  const [rewind, setRewind] = useState<RewindSettings | null>(null)

  useEffect(() => {
    void window.omi?.rewindGetSettings?.().then(setRewind)
    return window.omi?.onRewindSettings?.(setRewind)
  }, [])

  const on = !!rewind?.captureEnabled
  const change = (next: boolean): void => {
    if (!rewind) return
    const updated = { ...rewind, captureEnabled: next }
    setRewind(updated) // optimistic
    void window.omi?.rewindSetSettings?.(updated).then(setRewind)
  }

  return (
    <SettingRow
      icon={Monitor}
      dot={on ? 'on' : 'off'}
      title={t('Screen Capture', '屏幕截取')}
      subtitle={
        on
          ? t('Capturing your screen for Rewind', '正在为回顾截取屏幕')
          : t('Screen capture is paused', '屏幕截取已暂停')
      }
      keywords="screen capture rewind record monitor recording"
      control={
        <Toggle on={on} onChange={change} disabled={rewind === null} label={t('Screen Capture', '屏幕截取')} />
      }
    />
  )
}

// Audio Recording status card (macOS General §3.1). Bound to the `continuousRecording`
// preference — the same state the Sidebar's "Microphone" toggle drives — and live-syncs
// through the preferences listener when flipped elsewhere.
function AudioRecordingRow(): React.JSX.Element {
  const [on, setOn] = useState<boolean>(() => !!getPreferences().continuousRecording)

  useEffect(() => onPreferencesChange((p) => setOn(!!p.continuousRecording)), [])

  const change = (next: boolean): void => {
    setOn(next) // optimistic; setPreferences notifies subscribers to reconcile
    setPreferences({ continuousRecording: next })
  }

  return (
    <SettingRow
      icon={Mic}
      dot={on ? 'on' : 'off'}
      title={t('Audio Recording', '音频录制')}
      subtitle={
        on
          ? t('Recording and transcribing audio', '正在录制并转写音频')
          : t('Audio recording is paused', '音频录制已暂停')
      }
      keywords="audio recording microphone transcribe listening voice"
      control={<Toggle on={on} onChange={change} label={t('Audio Recording', '音频录制')} />}
    />
  )
}

// Screen Analysis master (macOS General "Screen Capture" consent, Windows-named
// "Screen Analysis" to avoid colliding with the local-Rewind "Screen Capture" row
// above). This is the single consent gate for the whole proactive screen loop —
// Focus, memory/task extraction, and insights. Today it is only reachable from the
// tray checkbox; this row exposes it in Settings. It reads/writes through the same
// scoped assistant bridge the tray and the Notifications tab use, and subscribes to
// the broadcast so it and the tray checkbox can never disagree.
export function ScreenAnalysisRow(): React.JSX.Element {
  const [on, setOn] = useState<boolean | null>(null)

  useEffect(() => {
    void window.omi?.assistantsGetSettings?.().then((s) => setOn(s.screenAnalysisEnabled))
    return window.omi?.onAssistantSettingsChanged?.((s) => setOn(s.screenAnalysisEnabled))
  }, [])

  const change = (next: boolean): void => {
    setOn(next) // optimistic; the coordinator re-syncs off the settings write
    void window.omi?.assistantsSetSettings?.({ screenAnalysisEnabled: next })
  }

  return (
    <SettingRow
      icon={ScanEye}
      dot={on ? 'on' : 'off'}
      title={t('Screen Analysis', '屏幕分析')}
      subtitle={t(
        "Master switch for Omi's proactive screen features — Focus, memory and task extraction, and insights. When off, Omi never analyzes your screen. Separate from Screen Capture above, which only records your local Rewind timeline.",
        '小蜗主动屏幕功能的总开关 —— 专注、记忆与任务提取、洞察。关闭后小蜗绝不分析你的屏幕。与上面的屏幕截取独立，后者只记录本地回顾时间线。'
      )}
      keywords="screen analysis proactive focus memory task insight vision master consent"
      control={
        <Toggle on={!!on} onChange={change} disabled={on === null} label={t('Screen Analysis', '屏幕分析')} />
      }
    />
  )
}

// Multi-chat sessions (macOS "Multiple Chat Sessions"). Off = the single Synced
// Chat thread shared with mobile; on = separate desktop chat threads with a
// history switcher. The multi-chat header also requires the pi_mono chat engine
// (a dark flag), so flipping this on under the default legacy engine has no
// visible effect yet — matching Mac, where multi-chat is kernel-backed.
function MultiChatRow(): React.JSX.Element {
  const [on, setOn] = useState(() => getPreferences().multiChatEnabled === true)

  useEffect(() => onPreferencesChange((p) => setOn(p.multiChatEnabled === true)), [])

  const change = (next: boolean): void => {
    setOn(next) // optimistic; setPreferences notifies subscribers to reconcile
    setPreferences({ multiChatEnabled: next })
  }

  return (
    <SettingRow
      icon={MessageSquarePlus}
      title={t('Multiple Chat Sessions', '多聊天会话')}
      subtitle={
        on
          ? t('Create separate chat threads', '创建独立聊天线程')
          : t('Single chat synced with the mobile app', '与手机应用同步的单条聊天')
      }
      keywords="multi chat sessions threads history switcher conversations separate"
      control={<Toggle on={on} onChange={change} label={t('Multiple Chat Sessions', '多聊天会话')} />}
    />
  )
}

// Escape hatch back to the original Home screen. The Home page subscribes to this
// preference, so the switch takes effect immediately — no restart.
function LegacyHomeRow(): React.JSX.Element {
  const [legacy, setLegacy] = useState(!!getPreferences().useLegacyHomeDesign)

  const change = (next: boolean): void => {
    setLegacy(next)
    setPreferences({ useLegacyHomeDesign: next })
  }

  return (
    <SettingRow
      icon={LayoutDashboard}
      dot={legacy ? 'off' : 'on'}
      title={t('New Home screen', '新版主页')}
      subtitle={t(
        'The redesigned Home — one stage with your stats, an ask bar, and suggestions. Turn this off to go back to the previous Home.',
        '重新设计的主页 —— 一个舞台呈现统计、提问栏和建议。关闭可回到旧版主页。'
      )}
      keywords="hub home dashboard layout redesign legacy old classic"
      control={
        <Toggle on={!legacy} onChange={(on) => change(!on)} label={t('Use the new Home screen', '使用新版主页')} />
      }
    />
  )
}
// Meeting detection (Phase 5): off / ask (default) / auto. Per-app overrides
// live in the same settings object (userData/app-settings.json → meeting.perApp,
// keyed by pattern id) — editable as JSON; no dedicated UI yet.
function MeetingDetectionRow(): React.JSX.Element {
  const [mode, setMode] = useState<MeetingMode | null>(null)

  useEffect(() => {
    void window.omi?.meetingGetSettings?.().then((s) => setMode(s.mode))
  }, [])

  const change = (next: MeetingMode): void => {
    setMode(next) // optimistic
    void window.omi?.meetingSetSettings?.({ mode: next })
  }

  return (
    <SettingRow
      icon={Presentation}
      dot={mode === 'off' ? 'off' : 'on'}
      title={t('Meeting detection', '会议检测')}
      subtitle={t(
        'When a meeting app is holding the microphone (Zoom, Teams, Meet, and more), Omi can capture and transcribe it — always with a visible notice, never silently.',
        '当会议应用占用麦克风时（Zoom、Teams、Meet 等），小蜗可以捕获并转写 —— 始终有可见提示，绝不静默。'
      )}
      keywords="meeting zoom teams meet webex discord detect auto capture record"
      control={
        <select
          value={mode ?? 'ask'}
          disabled={mode === null}
          onChange={(e) => change(e.target.value as MeetingMode)}
          className="rounded-md bg-white/10 px-2 py-1.5 text-sm text-white focus:outline-none"
        >
          <option value="ask" className="bg-neutral-900">
            {t('Ask before capturing (default)', '捕获前询问（默认）')}
          </option>
          <option value="auto" className="bg-neutral-900">
            {t('Capture automatically', '自动捕获')}
          </option>
          <option value="off" className="bg-neutral-900">
            {t('Off', '关闭')}
          </option>
        </select>
      }
    />
  )
}
// state from main on mount; the toggle writes it through and updates optimistically.
function LaunchAtLoginRow(): React.JSX.Element {
  const [openAtLogin, setOpenAtLogin] = useState<boolean | null>(null)
  // The OS Run entry is only writable in packaged builds (see the main handler);
  // in unpackaged dev the toggle must not pretend it works.
  const [supported, setSupported] = useState(true)

  useEffect(() => {
    void window.omi?.getLoginItemSettings?.().then((s) => {
      setOpenAtLogin(!!s?.openAtLogin)
      setSupported(!!s?.supported)
    })
  }, [])

  const change = (next: boolean): void => {
    setOpenAtLogin(next) // optimistic
    void window.omi?.setLaunchAtLogin?.(next)
  }

  return (
    <SettingRow
      icon={Power}
      dot={openAtLogin ? 'on' : 'off'}
      title={t('Launch at login', '开机自启')}
      subtitle={
        supported
          ? t('Start Omi automatically when you sign in to Windows.', '登录 Windows 时自动启动小蜗。')
          : t(
              'Start Omi automatically when you sign in to Windows. Available in installed builds only.',
              '登录 Windows 时自动启动小蜗。仅安装版可用。'
            )
      }
      keywords="startup autostart launch login boot start"
      control={
        <Toggle
          on={!!openAtLogin}
          onChange={change}
          disabled={openAtLogin === null || !supported}
          label={t('Launch at login', '开机自启')}
        />
      }
    />
  )
}

// Record hotkey and the "update ready" restart affordance moved to their topical
// tabs: Settings → Shortcuts (ShortcutsTab) and Settings → About (AboutTab).
