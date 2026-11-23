import { useEffect, useState } from 'react'
import { Mic, AppWindow, Power, type LucideIcon } from 'lucide-react'
import { t } from '../../lib/i18n'
import { brandName } from '../../../../shared/brand'
import { Toggle } from '../settings/Toggle'

// The three items every background/privacy consent surface shows. Shared by the
// onboarding step (BackgroundPrivacyStep) and the one-time interstitial for
// existing users so the wording and layout stay in lockstep. Continuous
// listening and launch-at-login are user-controlled; running in the tray is
// informational (always on for a resident companion app), shown as a static
// "Always on" chip rather than a toggle.
type Props = {
  listening: boolean
  onListeningChange: (next: boolean) => void
  launchAtLogin: boolean
  onLaunchAtLoginChange: (next: boolean) => void
}

function Row(props: {
  icon: LucideIcon
  title: string
  detail: string
  control: React.ReactNode
}): React.JSX.Element {
  const { icon: Icon, title, detail, control } = props
  return (
    <div className="flex w-full items-center gap-4 rounded-xl bg-white/[0.06] px-5 py-3.5 text-left">
      <Icon className="h-6 w-6 shrink-0 text-white/80" strokeWidth={1.75} />
      <div className="min-w-0 flex-1">
        <p className="text-sm font-semibold text-white">{title}</p>
        <p className="mt-0.5 text-xs leading-relaxed text-white/60">{detail}</p>
      </div>
      <div className="shrink-0">{control}</div>
    </div>
  )
}

export function BackgroundConsentControls({
  listening,
  onListeningChange,
  launchAtLogin,
  onLaunchAtLoginChange
}: Props): React.JSX.Element {
  // Launch-at-login is only writable in packaged builds (see the app:get-login-item
  // handler). In unpackaged dev the card stays visible but its toggle is disabled
  // so the UI never offers a switch that silently does nothing.
  const [launchSupported, setLaunchSupported] = useState(true)
  useEffect(() => {
    void window.omi?.getLoginItemSettings?.().then((s) => setLaunchSupported(!!s?.supported))
  }, [])

  return (
    <div className="flex w-full flex-col gap-3">
      <Row
        icon={Mic}
        title={t('Continuous listening', '持续聆听')}
        detail={t(
          'Omi listens through your microphone and turns what you hear into conversations automatically. Turn this off to listen only when you ask.',
          `${brandName()}通过麦克风聆听，并自动把听到的内容整理成对话。关闭后仅在你主动唤起时聆听。`
        )}
        control={
          <Toggle on={listening} onChange={onListeningChange} label={t('Continuous listening', '持续聆听')} />
        }
      />
      <Row
        icon={AppWindow}
        title={t('Runs in the background', '后台运行')}
        detail={t(
          "Omi stays in your system tray after you close the window, so it's ready the moment you need it. Quit any time from the tray.",
          `关闭窗口后${brandName()}仍驻留在系统托盘，随时待命。可随时从托盘退出。`
        )}
        control={
          <span className="rounded-full bg-white/10 px-2.5 py-1 text-xs font-medium text-white/70">
            {t('Always on', '始终开启')}
          </span>
        }
      />
      <Row
        icon={Power}
        title={t('Launch at login', '开机自启')}
        detail={
          launchSupported
            ? t('Start Omi automatically when you sign in to Windows.', `登录 Windows 时自动启动${brandName()}。`)
            : t('Start Omi automatically when you sign in to Windows. Available in installed builds only.', `登录 Windows 时自动启动${brandName()}。仅安装版可用。`)
        }
        control={
          <Toggle
            on={launchAtLogin}
            onChange={onLaunchAtLoginChange}
            disabled={!launchSupported}
            label={t('Launch at login', '开机自启')}
          />
        }
      />
    </div>
  )
}
