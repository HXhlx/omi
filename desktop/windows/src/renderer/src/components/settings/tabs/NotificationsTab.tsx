import { useEffect, useState } from 'react'
import { Bell, Gauge, Focus, Brain, Sparkles, Lightbulb } from 'lucide-react'
import { SettingRow } from '../SettingRow'
import { Toggle } from '../Toggle'
import { Slider } from '../controls/Slider'
import { t } from '../../../lib/i18n'
import type { AssistantSettingsView } from '../../../../../shared/types'

// Frequency levels 0–5, mirroring Mac's stepped slider labels and the interval
// table in main/assistants/core/notify.ts (LEVEL_INTERVALS_MS).
const FREQUENCY_LABELS = [
  t('Off', '关闭'),
  t('Minimal', '极少'),
  t('Low', '低'),
  t('Balanced', '均衡'),
  t('High', '高'),
  t('Maximum', '最高')
]
const FREQUENCY_CAPTIONS = [
  t('No proactive notifications', '无主动通知'),
  t('At most every 60 min', '最多每 60 分钟'),
  t('At most every 30 min', '最多每 30 分钟'),
  t('At most every 10 min', '最多每 10 分钟'),
  t('At most every 3 min', '最多每 3 分钟'),
  t('No limit', '不限')
]

/**
 * Notifications tab — the opt-in that unblocks proactive assistants. Windows ships
 * with notificationFrequency=0 (Off, matching Mac's post-migration default), so
 * every proactive toast (Insight/Focus/Goals) is permanently silent until the user
 * raises the frequency here. This tab is the only surface that lets them.
 *
 * Scoped bridge only (assistantsGetSettings/SetSettings) — a whitelisted view of
 * the central app-settings store, never a generic settings pass-through. Writing a
 * setting is the whole action: the proactive coordinator re-syncs on any write.
 */
export function NotificationsTab(): React.JSX.Element {
  const [settings, setSettings] = useState<AssistantSettingsView | null>(null)

  useEffect(() => {
    void window.omi.assistantsGetSettings().then(setSettings)
    // Stay in lock-step if the same flag is written elsewhere (tray checkbox, a
    // future backend sync) — the broadcast pushes the fresh projection.
    return window.omi.onAssistantSettingsChanged(setSettings)
  }, [])

  const patch = (p: Partial<AssistantSettingsView>): void => {
    setSettings((cur) => (cur ? { ...cur, ...p } : cur)) // optimistic
    void window.omi.assistantsSetSettings(p).then(setSettings)
  }

  const notifOn = !!settings?.notificationsEnabled
  const level = settings?.notificationFrequency ?? 0
  // Per-assistant rows read as OFF and grey out while the master toggle is off,
  // mirroring Mac's `if notificationsEnabled` reveal.
  const subDisabled = !settings || !notifOn

  return (
    <>
      <SettingRow
        icon={Bell}
        dot={notifOn ? 'on' : 'off'}
        title={t('Notifications', '通知')}
        subtitle={t("Control how often Omi's proactive assistants can notify you.", '控制小蜗主动助手通知你的频率。')}
        keywords="proactive notifications master enable assistants"
        control={
          <Toggle
            on={notifOn}
            onChange={(on) => patch({ notificationsEnabled: on })}
            disabled={!settings}
            label={t('Notifications', '通知')}
          />
        }
      />

      <SettingRow
        icon={Gauge}
        title={t('Frequency', '频率')}
        subtitle={t('How often to receive notifications.', '接收通知的频率。')}
        keywords="frequency rate throttle interval off minimal low balanced high maximum"
        note={
          level === 0 ? (
            <span className="text-xs text-amber-400/90">
              {t('Proactive notifications are off. Raise the frequency to let Omi notify you.', '主动通知已关闭。调高频率让小蜗可以通知你。')}
            </span>
          ) : undefined
        }
      >
        <div className="space-y-2">
          <div className="flex items-baseline justify-between text-sm">
            <span className="font-medium text-text-primary">{FREQUENCY_LABELS[level]}</span>
            <span className="text-text-tertiary">{FREQUENCY_CAPTIONS[level]}</span>
          </div>
          <Slider
            value={level}
            onChange={(v) => patch({ notificationFrequency: v })}
            min={0}
            max={5}
            step={1}
            ticks={[0, 1, 2, 3, 4, 5]}
            ariaLabel={t('Notification frequency', '通知频率')}
            disabled={!settings}
            leftLabel={<span className="text-xs">{t('Off', '关')}</span>}
            rightLabel={<span className="text-xs">{t('Max', '最高')}</span>}
          />
        </div>
      </SettingRow>

      <SettingRow
        icon={Focus}
        dot={settings && settings.focusNotificationsEnabled && notifOn ? 'on' : 'off'}
        title={t('Focus notifications', '专注通知')}
        subtitle={t('Show a notification on focus changes.', '专注状态变化时显示通知。')}
        keywords="focus notifications distraction refocus"
        note={
          <span className="text-xs text-text-tertiary">
            {t('Turning this off also pauses focus analysis entirely.', '关闭此项也会完全暂停专注分析。')}
          </span>
        }
        control={
          <Toggle
            on={!!settings?.focusNotificationsEnabled}
            onChange={(on) => patch({ focusNotificationsEnabled: on })}
            disabled={subDisabled}
            label={t('Focus notifications', '专注通知')}
          />
        }
      />

      <SettingRow
        icon={Brain}
        dot={settings && settings.memoryEnabled && notifOn ? 'on' : 'off'}
        title={t('Extract memories from your screen', '从屏幕提取记忆')}
        subtitle={t(
          'Periodically looks at your screen and saves useful facts to your Omi memories. Runs quietly — no notifications. Requires Screen Analysis (Settings → General).',
          '定期查看你的屏幕并把有用事实存入记忆。静默运行 —— 无通知。需要开启屏幕分析（设置 → 通用）。'
        )}
        keywords="memory notifications extraction screen facts memories synth"
        control={
          <Toggle
            on={!!settings?.memoryEnabled}
            onChange={(on) => patch({ memoryEnabled: on })}
            disabled={subDisabled}
            label={t('Extract memories from your screen', '从屏幕提取记忆')}
          />
        }
      />

      <SettingRow
        icon={Sparkles}
        dot={settings && settings.glowOverlayEnabled && notifOn ? 'on' : 'off'}
        title={t('Focus glow', '专注光环')}
        subtitle={t(
          'Draw a colored ring around the active window when Focus detects a distraction or a refocus.',
          '当专注检测到分心或重新专注时，在活动窗口周围画一圈彩色光环。'
        )}
        keywords="focus glow ring overlay halo distraction"
        control={
          <Toggle
            on={!!settings?.glowOverlayEnabled}
            onChange={(on) => patch({ glowOverlayEnabled: on })}
            disabled={subDisabled}
            label={t('Focus glow', '专注光环')}
          />
        }
      />

      <SettingRow
        icon={Lightbulb}
        title={t('Notification presentation', '通知呈现')}
        subtitle={t(
          'Notification style and screen privacy are configured in Settings → Rewind.',
          '通知样式和屏幕隐私在 设置 → 回顾 中配置。'
        )}
        keywords="insights proactive suggestion notification rewind"
      />
    </>
  )
}
