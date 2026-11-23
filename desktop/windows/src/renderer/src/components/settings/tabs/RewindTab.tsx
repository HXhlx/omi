import { useEffect, useState } from 'react'
import {
  Monitor,
  Clock,
  CalendarClock,
  Ban,
  Brain,
  Lightbulb,
  X,
  Mic,
  Trash2,
  Target,
  ScanText,
  Camera
} from 'lucide-react'
import { runScreenSynthesisOnce } from '../../../lib/screenSynthesis'
import { runRetentionSweep } from '../../../lib/retentionSweep'
import { BUILT_IN_EXCLUDED_APPS } from '../../../../../shared/rewindExclusions'
import { SettingRow } from '../SettingRow'
import { Toggle } from '../Toggle'
import { getPreferences, setPreferences } from '../../../lib/preferences'
import { t } from '../../../lib/i18n'
import { brandName } from '../../../../../shared/brand'
import type {
  RewindSettings,
  RewindCaptureQuality,
  ScreenSynthState,
  InsightSettings
} from '../../../../../shared/types'

export function RewindTab(): React.JSX.Element {
  const [rewind, setRewind] = useState<RewindSettings | null>(null)
  const [screenSynth, setScreenSynth] = useState<ScreenSynthState | null>(null)
  const [insight, setInsight] = useState<InsightSettings | null>(null)
  // "Automatically suggest goals" (Wave C). null until the main-process value loads.
  const [goalAutoGen, setGoalAutoGen] = useState<boolean | null>(null)
  const [newExcluded, setNewExcluded] = useState('')
  const [continuousRec, setContinuousRec] = useState<boolean>(
    () => !!getPreferences().continuousRecording
  )
  const toggleContinuous = (): void => {
    const next = !continuousRec
    setContinuousRec(next)
    setPreferences({ continuousRecording: next })
  }
  const [retention, setRetention] = useState<'off' | 'dry-run' | 'live'>(
    () => getPreferences().retentionMode ?? 'dry-run'
  )
  const changeRetention = (mode: 'off' | 'dry-run' | 'live'): void => {
    setRetention(mode)
    setPreferences({ retentionMode: mode })
    // Preview is a one-shot the user just asked for, so run it here — the 30-minute
    // background timer only runs 'live' passes now. Pressing Preview is what makes
    // the "logs what it would delete" subtitle true, instead of it happening 48x a
    // day whether or not anyone is looking.
    if (mode === 'dry-run') void runRetentionSweep('manual')
  }

  useEffect(() => {
    void window.omi.rewindGetSettings().then(setRewind)
    void window.omi.screenSynthGetState().then(setScreenSynth)
    void window.omi.insightGetSettings().then(setInsight)
    void window.omi.goalsGetAutoGeneration().then(setGoalAutoGen)
  }, [])

  const toggleGoalAutoGen = (on: boolean): void => {
    setGoalAutoGen(on) // optimistic
    void window.omi.goalsSetAutoGeneration(on).then(setGoalAutoGen)
  }

  const saveRewind = (next: RewindSettings): void => {
    setRewind(next) // optimistic
    void window.omi.rewindSetSettings(next).then(setRewind)
  }
  const addExcludedApp = (): void => {
    const name = newExcluded.trim()
    if (!rewind || !name) return
    setNewExcluded('')
    if (rewind.excludedApps.some((a) => a.toLowerCase() === name.toLowerCase())) return
    saveRewind({ ...rewind, excludedApps: [...rewind.excludedApps, name] })
  }
  const removeExcludedApp = (app: string): void => {
    if (!rewind) return
    saveRewind({ ...rewind, excludedApps: rewind.excludedApps.filter((a) => a !== app) })
  }
  const patchScreenSynth = async (patch: Partial<ScreenSynthState>): Promise<void> => {
    setScreenSynth(await window.omi.screenSynthSetState(patch))
  }
  const synthesizeNow = async (): Promise<void> => {
    await runScreenSynthesisOnce()
    setScreenSynth(await window.omi.screenSynthGetState())
  }
  const patchInsight = async (patch: Partial<InsightSettings>): Promise<void> => {
    setInsight(await window.omi.insightSetSettings(patch))
  }

  return (
    <>
      <SettingRow
        icon={Mic}
        dot={continuousRec ? 'on' : 'off'}
        title={t('Continuous recording', '持续录音')}
        subtitle={t(
          'Always-on microphone. Omi turns what you hear into conversations automatically.',
          '麦克风常开，小蜗自动把听到的内容整理成对话。'
        )}
        keywords="continuous recording microphone audio always-on"
        control={
          <Toggle on={continuousRec} onChange={toggleContinuous} label={t('Continuous recording', '持续录音')} />
        }
      />
      <SettingRow
        icon={Trash2}
        title={t('Auto-cleanup', '自动清理')}
        subtitle={t(
          'Remove empty conversations and junk memories. Preview logs what it would delete; switch to Delete to apply.',
          '清除空对话和无用记忆。“预览”只记录将删除的内容，切到“删除”才真正执行。'
        )}
        keywords="retention cleanup delete conversations memories sweep"
      >
        <div className="flex gap-1">
          {(['off', 'dry-run', 'live'] as const).map((m) => (
            <button
              key={m}
              onClick={() => changeRetention(m)}
              className={
                retention === m
                  ? 'rounded-md bg-white/15 px-2.5 py-1 text-xs text-white'
                  : 'rounded-md px-2.5 py-1 text-xs text-white/50 hover:text-white/80'
              }
            >
              {m === 'off' ? t('Off', '关闭') : m === 'dry-run' ? t('Preview', '预览') : t('Delete', '删除')}
            </button>
          ))}
        </div>
      </SettingRow>
      <SettingRow
        icon={Monitor}
        dot={rewind?.captureEnabled ? 'on' : 'off'}
        title={t('Capture my screen', '定时截取')}
        subtitle={t(
          'A local, searchable timeline stored only on this PC — never uploaded.',
          '本地可搜索的时间线，仅存于这台电脑 —— 绝不上传。'
        )}
        keywords="rewind screen capture record"
        control={
          <Toggle
            on={!!rewind?.captureEnabled}
            onChange={(on) => rewind && saveRewind({ ...rewind, captureEnabled: on })}
            disabled={!rewind}
            label={t('Capture my screen', '定时截取')}
          />
        }
      />
      <SettingRow
        icon={Clock}
        title={t('Capture interval', '截取间隔')}
        subtitle={t('How often a frame is sampled.', '每隔多久采样一帧。')}
        keywords="rewind frequency seconds"
        control={
          <select
            value={rewind?.intervalMs ?? 1000}
            onChange={(e) =>
              rewind && saveRewind({ ...rewind, intervalMs: Number(e.target.value) })
            }
            disabled={!rewind}
            className="rounded-md bg-white/10 px-2 py-1.5 text-sm text-white focus:outline-none disabled:opacity-40"
          >
            <option value={1000} className="bg-neutral-900">
              {t('Every 1s', '每 1 秒')}
            </option>
            <option value={2000} className="bg-neutral-900">
              {t('Every 2s', '每 2 秒')}
            </option>
            <option value={5000} className="bg-neutral-900">
              {t('Every 5s', '每 5 秒')}
            </option>
            <option value={10000} className="bg-neutral-900">
              {t('Every 10s', '每 10 秒')}
            </option>
          </select>
        }
      />
      {/* LOCAL ADAPT (XiaoWo): observation source — screen (upstream) or camera
          (real-world observation for the accessibility assistant). */}
      <SettingRow
        icon={Camera}
        title={t('Capture source', '截取来源')}
        subtitle={t(
          'Screen captures your display; Camera observes the real world through the default camera.',
          '屏幕截取显示器画面；摄像头通过默认摄像头观察真实世界。'
        )}
        keywords="rewind camera source observation 摄像头 拍照"
        control={
          <select
            value={rewind?.captureSource ?? 'screen'}
            onChange={(e) =>
              rewind &&
              saveRewind({ ...rewind, captureSource: e.target.value as 'screen' | 'camera' })
            }
            disabled={!rewind}
            className="rounded-md bg-white/10 px-2 py-1.5 text-sm text-white focus:outline-none disabled:opacity-40"
          >
            <option value="screen" className="bg-neutral-900">
              {t('Screen', '屏幕')}
            </option>
            <option value="camera" className="bg-neutral-900">
              {t('Camera', '摄像头')}
            </option>
          </select>
        }
      />
      <SettingRow
        icon={ScanText}
        title={t('Capture quality', '截取画质')}
        subtitle={t(
          'Higher quality makes small on-screen text readable (better search and OCR), and uses more CPU and disk.',
          '更高画质让小字更清晰（搜索和 OCR 更准），但更耗 CPU 和磁盘。'
        )}
        keywords="rewind resolution quality ocr sharpness readable text"
        control={
          <select
            value={rewind?.captureQuality ?? 'standard'}
            onChange={(e) =>
              rewind &&
              saveRewind({ ...rewind, captureQuality: e.target.value as RewindCaptureQuality })
            }
            disabled={!rewind}
            className="rounded-md bg-white/10 px-2 py-1.5 text-sm text-white focus:outline-none disabled:opacity-40"
          >
            <option value="standard" className="bg-neutral-900">
              {t('Standard (720p)', '标准（720p）')}
            </option>
            <option value="high" className="bg-neutral-900">
              {t('High (1080p)', '高（1080p）')}
            </option>
            <option value="max" className="bg-neutral-900">
              {t('Maximum (1440p)', '最高（1440p）')}
            </option>
          </select>
        }
      />
      <SettingRow
        icon={CalendarClock}
        title={t('Keep history for', '历史保留时长')}
        subtitle={t('Older frames are pruned automatically.', '更早的画面会被自动清理。')}
        keywords="rewind retention days delete"
        control={
          <div className="flex items-center gap-2 text-sm text-text-secondary">
            <input
              type="number"
              min={1}
              value={rewind?.retentionDays ?? 14}
              onChange={(e) => {
                const days = Number(e.target.value)
                if (rewind && Number.isFinite(days) && days >= 1)
                  saveRewind({ ...rewind, retentionDays: days })
              }}
              disabled={!rewind}
              className="w-16 rounded-md bg-white/10 px-2 py-1.5 text-white focus:outline-none disabled:opacity-40"
            />
            {t('days', '天')}
          </div>
        }
      />
      <SettingRow
        icon={Ban}
        title={t('Excluded apps', '排除的应用')}
        subtitle={t(
          'Rewind never screenshots while one of these apps is in focus. Matched loosely (e.g. “chrome” covers Google Chrome).',
          '这些应用处于前台时不截屏。模糊匹配（如“chrome”可覆盖 Google Chrome）。'
        )}
        keywords="rewind exclude block private app capture"
      >
        <div className="space-y-3">
          <div className="flex gap-2">
            <input
              value={newExcluded}
              onChange={(e) => setNewExcluded(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  e.preventDefault()
                  addExcludedApp()
                }
              }}
              placeholder={t('App name (e.g. Banking)', '应用名（如：银行）')}
              className="flex-1 rounded-lg bg-white/10 px-3 py-2 text-sm text-text-secondary focus:outline-none"
            />
            <button
              onClick={addExcludedApp}
              disabled={!newExcluded.trim()}
              className="btn-ghost disabled:opacity-40"
            >
              {t('Add', '添加')}
            </button>
          </div>
          {/* User additions — removable. */}
          {rewind && rewind.excludedApps.length > 0 && (
            <ul className="flex flex-wrap gap-2">
              {rewind.excludedApps.map((app) => (
                <li
                  key={app}
                  className="flex items-center gap-1.5 rounded-full bg-white/10 py-1 pl-3 pr-1.5 text-sm text-text-secondary"
                >
                  <span className="max-w-[16rem] truncate">{app}</span>
                  <button
                    onClick={() => removeExcludedApp(app)}
                    aria-label={t(`Remove ${app}`, `移除 ${app}`)}
                    className="rounded-full p-0.5 text-white/50 transition-colors hover:bg-white/10 hover:text-white"
                  >
                    <X className="h-3.5 w-3.5" />
                  </button>
                </li>
              ))}
            </ul>
          )}
          {/* Built-in, always-on exclusions (not removable). */}
          <div className="rounded-lg bg-white/[0.04] px-3 py-2 text-xs leading-relaxed text-text-tertiary">
            <span className="text-text-secondary">{t('Always excluded:', '始终排除：')}</span>{' '}
            {[brandName(), ...BUILT_IN_EXCLUDED_APPS].join(' · ')}。
            <span className="mt-1 block">
              {t(
                'Login, password, and private-browsing screens are skipped automatically (by window title).',
                '登录、密码和隐私浏览窗口会自动跳过（按窗口标题识别）。'
              )}
            </span>
          </div>
        </div>
      </SettingRow>

      <SettingRow
        icon={Brain}
        dot={screenSynth?.enabled ? 'on' : 'off'}
        title={t('Screen activity → memories', '屏幕活动 → 记忆')}
        subtitle={t(
          'Turns recent on-screen text (from Rewind) into memories. On-device redaction first; skips private/incognito windows. Off by default — writes to your Omi account.',
          '把最近的屏幕文字（来自回溯）提炼成记忆。先在本机脱敏，跳过隐私/无痕窗口。默认关闭 —— 会写入你的账号。'
        )}
        keywords="synthesis screen memories gemini"
        control={
          <Toggle
            on={!!screenSynth?.enabled}
            onChange={(on) => void patchScreenSynth({ enabled: on })}
            disabled={!screenSynth}
            label={t('Screen activity to memories', '屏幕活动转记忆')}
          />
        }
      >
        {screenSynth && (
          <div className="space-y-2">
            <textarea
              rows={2}
              placeholder={t(
                'Denylist — one app/site keyword per line (e.g. therapy, salary)',
                '屏蔽清单 —— 每行一个应用/网站关键词（如：医疗、工资）'
              )}
              defaultValue={screenSynth.denylist.join('\n')}
              onBlur={(e) =>
                void patchScreenSynth({
                  denylist: e.target.value
                    .split('\n')
                    .map((s) => s.trim())
                    .filter(Boolean)
                })
              }
              className="w-full rounded-lg bg-white/10 px-3 py-2 text-sm text-text-secondary focus:outline-none"
            />
            <div className="flex items-center justify-between">
              <span className="text-xs text-text-tertiary">
                {screenSynth.lastRunAt
                  ? t(
                      `Last run ${new Date(screenSynth.lastRunAt).toLocaleString()} — ${screenSynth.lastCount} memories`,
                      `上次运行 ${new Date(screenSynth.lastRunAt).toLocaleString('zh-CN')} —— ${screenSynth.lastCount} 条记忆`
                    )
                  : t('Not run yet', '尚未运行')}
              </span>
              <button onClick={() => void synthesizeNow()} className="btn-ghost">
                {t('Synthesize now', '立即提炼')}
              </button>
            </div>
          </div>
        )}
      </SettingRow>

      <SettingRow
        icon={Lightbulb}
        title={t('Notification presentation', '通知展示方式')}
        subtitle={t('Choose how Omi displays notifications.', '选择小蜗展示通知的方式。')}
        keywords="notifications style privacy"
      >
        {insight && (
          <div className="space-y-3">
            <label className="flex items-center gap-2 text-sm text-text-secondary">
              {t('Notification style', '通知样式')}
              <select
                value={insight.notificationStyle}
                onChange={(e) =>
                  void patchInsight({
                    notificationStyle: e.target.value as 'omi' | 'native'
                  })
                }
                className="rounded-md bg-white/10 px-2 py-1.5 text-white focus:outline-none"
              >
                <option value="omi" className="bg-neutral-900">
                  {t('Omi notification', '小蜗内置通知')}
                </option>
                <option value="native" className="bg-neutral-900">
                  {t('Windows notification', 'Windows 系统通知')}
                </option>
              </select>
            </label>
            <button onClick={() => window.omi.insightTest()} className="btn-ghost self-start">
              {t('Send a test notification', '发送测试通知')}
            </button>

          </div>
        )}
      </SettingRow>

      <SettingRow
        icon={Target}
        dot={goalAutoGen ? 'on' : 'off'}
        title={t('Automatically suggest goals', '自动推荐目标')}
        subtitle={t(
          'Occasionally reviews your memories, conversations, and tasks on-device and creates a goal it thinks fits you. Off by default; you can always use Suggest on the Goals page.',
          '偶尔在本机回顾你的记忆、对话和任务，生成一个适合你的目标。默认关闭；也可随时在“目标”页点击推荐。'
        )}
        keywords="goals suggest auto generate proactive"
        control={
          <Toggle
            on={!!goalAutoGen}
            onChange={toggleGoalAutoGen}
            disabled={goalAutoGen === null}
            label={t('Automatically suggest goals', '自动推荐目标')}
          />
        }
      />
    </>
  )
}
