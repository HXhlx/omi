// Settings → Advanced → "Developer API Keys" subsection: bring-your-own-key
// (BYOK). Configure at least one LLM provider key (Deepgram is optional) and
// Omi runs on your keys — the "free forever" plan — with no Omi subscription
// charge. Ported from the macOS DeveloperKeys section
// (SettingsContentView+DeveloperKeys.swift): same capability-scoped model,
// same copy, same up-front live validation before the backend is ever flipped
// on.
//
// Keys are encrypted at rest in the main process (ByokKeyStore, DPAPI). This UI
// never persists or logs raw keys; enrollment sends only SHA-256 fingerprints.

import { useEffect, useRef, useState } from 'react'
import { KeyRound, ShieldCheck, AlertTriangle, Eye, EyeOff, Loader2 } from 'lucide-react'
import { SettingRow } from '../SettingRow'
import { auth } from '../../../lib/firebase'
import { dismissUsageLimit } from '../../../lib/usageLimit'
import { fetchSubscription, fetchChatQuota } from '../../../lib/billing'
import {
  BYOK_PROVIDERS,
  BYOK_LLM_PROVIDERS,
  isByokActive,
  type ByokProvider,
  type ByokValidationResults
} from '../../../../../shared/byok'
import { t } from '../../../lib/i18n'

/** Field metadata per provider — titles/subtitles verbatim from the macOS view. */
const PROVIDERS: { id: ByokProvider; title: string; subtitle: string; displayName: string }[] = [
  {
    id: 'openrouter',
    title: t('OpenRouter API Key', 'OpenRouter API 密钥'),
    subtitle: t('For OpenRouter models.', '用于 OpenRouter 模型。'),
    displayName: 'OpenRouter'
  },
  { id: 'openai', title: t('OpenAI API Key', 'OpenAI API 密钥'), subtitle: t('For GPT calls.', '用于 GPT 调用。'), displayName: 'OpenAI' },
  {
    id: 'anthropic',
    title: t('Anthropic API Key', 'Anthropic API 密钥'),
    subtitle: t('For chat (Claude).', '用于聊天（Claude）。'),
    displayName: 'Anthropic'
  },
  {
    id: 'gemini',
    title: t('Gemini API Key', 'Gemini API 密钥'),
    subtitle: t('For proactive AI (memory, tasks, insights, focus).', '用于主动 AI（记忆、任务、洞察、专注）。'),
    displayName: 'Gemini'
  },
  {
    id: 'deepgram',
    title: t('Deepgram API Key', 'Deepgram API 密钥'),
    subtitle: t('For live transcription.', '用于实时转写。'),
    displayName: 'Deepgram'
  }
]

const emptyKeys = (): Record<ByokProvider, string> => ({
  openrouter: '',
  openai: '',
  anthropic: '',
  gemini: '',
  deepgram: ''
})

// Mac fires refreshBYOKActivation on every keystroke; we debounce so a paste or
// fast typing doesn't storm the provider endpoints or POST/DELETE repeatedly.
const COMMIT_DEBOUNCE_MS = 600

export function DeveloperKeysSection(): React.JSX.Element {
  const [keys, setKeys] = useState<Record<ByokProvider, string>>(emptyKeys)
  const [statuses, setStatuses] = useState<ByokValidationResults>({})
  const [checking, setChecking] = useState(false)
  const [activationError, setActivationError] = useState<string | null>(null)
  // Whether the backend enrollment actually succeeded — the banner must not
  // claim "Free plan active" off key presence alone: an invalid or rejected key
  // stays in the fields while activation stays off.
  const [validatedProviders, setValidatedProviders] = useState<ByokProvider[] | null>(null)
  const [reveal, setReveal] = useState<Record<ByokProvider, boolean>>({
    openrouter: false,
    openai: false,
    anthropic: false,
    gemini: false,
    deepgram: false
  })

  // Latest keys for the debounced commit (avoids a stale closure), plus the
  // pending timer so rapid edits collapse into one validate/enroll.
  const keysRef = useRef<Record<ByokProvider, string>>(emptyKeys())
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const enrollGenRef = useRef(0)

  // Load stored keys once on mount so the fields reflect what's saved. We do NOT
  // validate on open (no network on open) — the banner reflects the LAST
  // enrollment outcome (validated providers from main), not field presence;
  // badges populate after a change triggers enrollment (Mac parity).
  useEffect(() => {
    void window.omi.byokGetAll().then((stored) => {
      const merged = { ...emptyKeys(), ...stored }
      keysRef.current = merged
      setKeys(merged)
    })
    void window.omi
      .byokValidatedProviders()
      .then(setValidatedProviders)
      .catch(() => setValidatedProviders(null))
    return () => {
      if (timerRef.current) clearTimeout(timerRef.current)
    }
  }, [])

  const hasActiveLLMByok = validatedProviders?.some((p) => BYOK_LLM_PROVIDERS.includes(p)) ?? false
  const hasTranscriptionByok = validatedProviders?.includes('deepgram') ?? false
  const hasAnyKey = BYOK_PROVIDERS.some((p) => keys[p].trim().length > 0)

  // Persist the current key set, then reconcile backend activation. Runs
  // debounced after edits (not per keystroke).
  const commit = async (): Promise<void> => {
    const gen = ++enrollGenRef.current
    const cur = keysRef.current
    await Promise.all(BYOK_PROVIDERS.map((p) => window.omi.byokSet(p, cur[p].trim())))
    // Live-validate when an LLM key is configured; Deepgram remains optional.
    const willValidate = isByokActive(cur)
    setChecking(willValidate)
    setActivationError(null)
    const token = await auth.currentUser?.getIdToken().catch(() => undefined)
    if (!token) {
      // Not signed in — keys are saved; enrollment happens once authenticated.
      const validated = await window.omi.byokValidatedProviders().catch(() => null)
      if (gen !== enrollGenRef.current) return
      setValidatedProviders(validated)
      setChecking(false)
      return
    }
    const result = await window.omi.byokEnroll(token)
    const validated = await window.omi.byokValidatedProviders().catch(() => null)
    if (gen !== enrollGenRef.current) return
    setValidatedProviders(validated)
    setChecking(false)
    setStatuses(result.results)
    if (result.active) {
      setActivationError(null)
      // Mac parity: on activation, refresh plan/quota and clear any sticky
      // paywall so a user who just hit their limit isn't left blocked.
      dismissUsageLimit()
      void fetchSubscription().catch(() => {})
      void fetchChatQuota().catch(() => {})
    } else if (result.backendError) {
      // The enroll POST failed; the store retains prior enrollment evidence
      // only for keys that still match its accepted fingerprints.
      setActivationError(t("Couldn't reach Omi to switch on the free plan. Try again.", '无法连接服务器开启免费套餐。请重试。'))
    } else {
      // Deactivate DELETE sent (or every LLM key rejected) — the free plan is off.
      if (willValidate) {
        const rejected = PROVIDERS.filter((p) => result.results[p.id] && !result.results[p.id]?.ok)
          .map((p) => p.displayName)
          .sort()
        setActivationError(
          rejected.length
            ? t(
                `Rejected by provider: ${rejected.join(', ')}. Free plan stays off until an LLM key authenticates.`,
                `被供应商拒绝：${rejected.join(', ')}。在某个 LLM 密钥通过鉴权前，免费套餐保持关闭。`
              )
            : null
        )
      }
    }
  }

  const scheduleCommit = (): void => {
    if (timerRef.current) clearTimeout(timerRef.current)
    timerRef.current = setTimeout(() => void commit(), COMMIT_DEBOUNCE_MS)
  }

  const onFieldChange = (provider: ByokProvider, value: string): void => {
    keysRef.current = { ...keysRef.current, [provider]: value }
    setKeys((k) => ({ ...k, [provider]: value }))
    scheduleCommit()
  }

  const clearAll = async (): Promise<void> => {
    if (timerRef.current) clearTimeout(timerRef.current)
    keysRef.current = emptyKeys()
    setKeys(emptyKeys())
    setStatuses({})
    setActivationError(null)
    setChecking(false)
    setValidatedProviders([])
    await window.omi.byokClearAll()
    const token = await auth.currentUser?.getIdToken().catch(() => undefined)
    if (token) await window.omi.byokEnroll(token) // deactivates (empty set)
  }

  return (
    <div>
      {/* Subsection header — Mac's "Developer API Keys" (key icon). */}
      <div className="mb-4 mt-2 flex items-center gap-2 border-t border-white/[0.06] pt-6">
        <KeyRound className="h-4 w-4 text-white/45" strokeWidth={1.9} />
        <h3 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">
          {t('Developer API Keys', '开发者 API 密钥')}
        </h3>
      </div>

      {/* Status banner — verbatim macOS copy, "this Mac" adapted to "this PC". */}
      <div className="mb-4 flex items-start gap-3 rounded-xl border border-white/[0.08] bg-white/[0.03] p-4">
        {hasActiveLLMByok ? (
          <ShieldCheck className="mt-0.5 h-5 w-5 shrink-0 text-emerald-400" strokeWidth={1.75} />
        ) : (
          <KeyRound className="mt-0.5 h-5 w-5 shrink-0 text-white/55" strokeWidth={1.75} />
        )}
        <div className="min-w-0">
          <div className="text-[15px] font-semibold text-text-primary">
            {hasActiveLLMByok ? t('Chat and AI: BYOK keys active', '聊天与 AI：BYOK 密钥已激活') : t('Bring your own keys', '自带密钥')}
          </div>
          <div className="mt-0.5 text-sm text-text-tertiary">
            {hasActiveLLMByok
              ? t('Your LLM keys cover supported chat and AI features. Keys stay on this PC.', '你的 LLM 密钥覆盖支持的聊天和 AI 功能。密钥只留在这台电脑。')
              : t('Add an LLM key for supported chat and AI features. OpenRouter is preferred when configured. Keys stay on this PC — we never store them on our servers.', '添加 LLM 密钥以使用支持的聊天和 AI 功能。配置后优先走 OpenRouter。密钥只留在这台电脑 —— 我们绝不存到服务器。')}
          </div>
          <div className="mt-2 text-sm text-text-tertiary">
            {t(
              'A validated Deepgram key is required for BYOK transcription. Without it, your Omi transcription allowance and conversation locks still apply.',
              'BYOK 转写需要一个通过验证的 Deepgram 密钥。没有它，仍按套餐转写额度和对话锁执行。'
            )}
          </div>
          <div className="mt-2 text-sm text-text-tertiary">
            {hasTranscriptionByok
              ? t('Transcription: Deepgram BYOK', '转写：Deepgram BYOK')
              : validatedProviders
                ? t('Transcription: Omi plan allowance', '转写：套餐额度')
                : t('Transcription status unavailable — reopen settings to check', '转写状态不可用 —— 重新打开设置查看')}
          </div>
        </div>
      </div>

      {activationError && (
        <div className="mb-4 flex items-start gap-2 rounded-lg border border-amber-400/25 bg-amber-400/[0.06] px-4 py-3">
          <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-400" />
          <span className="text-sm text-amber-400">{activationError}</span>
        </div>
      )}

      {PROVIDERS.map(({ id, title, subtitle, displayName }) => {
        const status = statuses[id]
        const showChecking = checking && keys[id].trim().length > 0
        const dot = status?.ok ? 'on' : status && !status.ok ? 'warn' : undefined
        return (
          <SettingRow
            key={id}
            title={title}
            subtitle={subtitle}
            keywords={`${id} ${displayName} api key byok developer bring your own key`}
            dot={dot}
            control={
              showChecking ? (
                <span className="flex items-center gap-1.5 text-sm text-text-tertiary">
                  <Loader2 className="h-3.5 w-3.5 animate-spin" />
                  {t('Checking…', '验证中…')}
                </span>
              ) : status?.ok ? (
                <span className="text-sm font-semibold text-emerald-400">{t('Valid', '有效')}</span>
              ) : status && !status.ok ? (
                <span className="text-sm font-semibold text-amber-400">{t('Invalid', '无效')}</span>
              ) : undefined
            }
          >
            <div className="relative">
              <input
                type={reveal[id] ? 'text' : 'password'}
                value={keys[id]}
                onChange={(e) => onFieldChange(id, e.target.value)}
                placeholder={t('Leave blank for default', '留空使用默认')}
                className="glass-subtle w-full rounded-lg px-4 py-3 pr-11 font-mono text-sm text-text-secondary focus:outline-none"
                spellCheck={false}
                autoComplete="off"
              />
              <button
                type="button"
                onClick={() => setReveal((r) => ({ ...r, [id]: !r[id] }))}
                className="absolute right-3 top-1/2 -translate-y-1/2 text-white/45 hover:text-white/75"
                aria-label={reveal[id] ? t(`Hide ${title}`, `隐藏 ${title}`) : t(`Show ${title}`, `显示 ${title}`)}
              >
                {reveal[id] ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
              </button>
            </div>
            {status && !status.ok && status.detail && (
              <div className="mt-2 text-xs text-amber-400">{status.detail}</div>
            )}
          </SettingRow>
        )
      })}

      {hasAnyKey && (
        <div className="mt-5 flex justify-center">
          <button
            onClick={() => void clearAll()}
            className="text-sm font-medium text-red-400 hover:text-red-300"
          >
            {t('Clear All Custom Keys', '清除全部自定义密钥')}
          </button>
        </div>
      )}
    </div>
  )
}
