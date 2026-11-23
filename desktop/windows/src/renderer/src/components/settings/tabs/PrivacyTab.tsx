import { useEffect, useState } from 'react'
import { Activity, EyeOff, Monitor, ShieldCheck } from 'lucide-react'
import { SettingRow } from '../SettingRow'
import { Toggle } from '../Toggle'
import { t } from '../../../lib/i18n'
import type { UsageSettings } from '../../../../../shared/types'

const RETENTION_OPTIONS: ReadonlyArray<{ days: number; label: string }> = [
  { days: 30, label: t('30 days', '30 天') },
  { days: 45, label: t('45 days (recommended)', '45 天（推荐）') },
  { days: 60, label: t('60 days', '60 天') },
  { days: 90, label: t('90 days', '90 天') },
  { days: 180, label: t('180 days', '180 天') }
]

export function PrivacyTab(): React.JSX.Element {
  const [usage, setUsage] = useState<UsageSettings | null>(null)
  useEffect(() => {
    window.omi
      .usageGetSettings()
      .then(setUsage)
      .catch(() => setUsage(null))
  }, [])
  const saveUsage = async (next: UsageSettings): Promise<void> => {
    setUsage(await window.omi.usageSetSettings(next))
  }

  // Bar/HUD screen-share privacy: exclude the top-edge bar from captures
  // (WDA_EXCLUDEFROMCAPTURE). Persisted in main's app settings; applied live.
  const [hudProtected, setHudProtected] = useState<boolean | null>(null)
  useEffect(() => {
    window.omiBar
      .getContentProtection()
      .then(setHudProtected)
      .catch(() => setHudProtected(null))
  }, [])
  const toggleHudProtection = (on: boolean): void => {
    setHudProtected(on)
    void window.omiBar.setContentProtection(on).then(setHudProtected)
  }

  // "Screen Sharing in Chat" (Mac's chatScreenshotSharingEnabled, default ON).
  // The consent gate for the model-invoked capture_screen tool: on → Omi may
  // capture the screen when you ask about it; off → the tool is refused. Turning
  // it on captures nothing by itself — it only permits the tool.
  const [screenShareInChat, setScreenShareInChat] = useState<boolean | null>(null)
  useEffect(() => {
    window.omi
      .getChatScreenshotSharing()
      .then(setScreenShareInChat)
      .catch(() => setScreenShareInChat(null))
  }, [])
  const toggleScreenShareInChat = (on: boolean): void => {
    setScreenShareInChat(on)
    void window.omi.setChatScreenshotSharing(on).then(setScreenShareInChat)
  }

  return (
    <>
      <SettingRow
        icon={Activity}
        dot={usage?.enabled ? 'on' : 'off'}
        title={t('App-usage tracking', '应用使用跟踪')}
        subtitle={t(
          'Records which apps you actively use (app name only, never window titles) — locally — to improve memory ranking.',
          '在本地记录你活跃使用的应用（仅应用名，绝不记窗口标题），用于改进记忆排序。'
        )}
        keywords="usage foreground app tracking privacy"
        control={
          <Toggle
            on={!!usage?.enabled}
            onChange={(on) => usage && void saveUsage({ ...usage, enabled: on })}
            disabled={!usage}
            label={t('App-usage tracking', '应用使用跟踪')}
          />
        }
      >
        {usage?.enabled && (
          <label className="flex items-center gap-2 text-sm text-text-secondary">
            <span>{t('Forget apps not used in', '遗忘未使用的应用：')}</span>
            <select
              value={usage.retentionDays}
              onChange={(e) => void saveUsage({ ...usage, retentionDays: Number(e.target.value) })}
              className="rounded-md bg-white/10 px-3 py-1.5 text-sm text-white focus:outline-none"
            >
              {RETENTION_OPTIONS.map((o) => (
                <option key={o.days} value={o.days} className="bg-neutral-900">
                  {o.label}
                </option>
              ))}
            </select>
          </label>
        )}
      </SettingRow>
      <SettingRow
        icon={EyeOff}
        dot={hudProtected ? 'on' : 'off'}
        title={t('Hide the Omi bar from screen sharing', '屏幕共享时隐藏悬浮栏')}
        subtitle={t(
          'Excludes the top-edge bar from screenshots, recordings, and shared screens. Turn off if you want it visible in captures.',
          '把顶部悬浮栏从截图、录屏和共享屏幕中排除。想让它在捕获中可见就关闭。'
        )}
        keywords="bar hud screen share capture protection privacy exclude recording"
        control={
          <Toggle
            on={!!hudProtected}
            onChange={toggleHudProtection}
            disabled={hudProtected === null}
            label={t('Hide the Omi bar from screen sharing', '屏幕共享时隐藏悬浮栏')}
          />
        }
      />
      <SettingRow
        icon={Monitor}
        dot={screenShareInChat ? 'on' : 'off'}
        title={t('Screen Sharing in Chat', '聊天中的屏幕共享')}
        subtitle={t(
          "Let Omi capture your screen when you ask about what's on it. Omi only captures when you ask — turning this on doesn't share anything on its own.",
          '当你询问屏幕内容时允许小蜗截屏。小蜗只在你开口时截取 —— 开启本身不会共享任何内容。'
        )}
        keywords="screen sharing chat capture screenshot ask omi see my screen vision"
        control={
          <Toggle
            on={!!screenShareInChat}
            onChange={toggleScreenShareInChat}
            disabled={screenShareInChat === null}
            label={t('Screen Sharing in Chat', '聊天中的屏幕共享')}
          />
        }
      />
      <SettingRow
        icon={ShieldCheck}
        title={t('On-device by default', '默认本地存储')}
        subtitle={t(
          'Your screen timeline, file index, and app usage stay on this PC. Only synthesized facts (memories) are sent to your Omi account, and only for features you turn on.',
          '你的屏幕时间线、文件索引和应用使用记录都留在这台电脑。只有合成的事实（记忆）会发送到你的账户，且仅限你开启的功能。'
        )}
        keywords="privacy local data on-device cloud"
      />
    </>
  )
}
