import { useState } from 'react'
import { StepScaffold } from './StepScaffold'
import { t } from '../../lib/i18n'

type LanguageStepProps = {
  stepIndex: number
  totalSteps: number
  initialValue: string
  onContinue: (language: string) => void
  onBack: () => void
  aside?: React.ReactNode
}

export function LanguageStep({
  stepIndex,
  totalSteps,
  initialValue,
  onContinue,
  onBack,
  aside
}: LanguageStepProps): React.JSX.Element {
  const [mode, setMode] = useState<'chinese' | 'english' | 'other'>(() => {
    // LOCAL ADAPT: Chinese is the default speech language on this machine —
    // it matches the local FunASR single-language profile. An existing
    // preference still wins so re-entering the wizard reflects reality.
    if (!initialValue) return 'chinese'
    if (initialValue === 'zh') return 'chinese'
    if (initialValue === 'en') return 'english'
    return 'other'
  })
  const [other, setOther] = useState(
    initialValue && initialValue !== 'en' && initialValue !== 'zh' ? initialValue : ''
  )
  const trimmed = other.trim()

  return (
    <StepScaffold
      stepIndex={stepIndex}
      totalSteps={totalSteps}
      eyebrow={t('LANGUAGE', '语言')}
      title={t('Pick your language.', '选择你的语言。')}
      align="left"
      onBack={onBack}
      aside={aside}
    >
      <div className="flex gap-3">
        <button
          type="button"
          onClick={() => onContinue('zh')}
          className={
            'rounded-xl px-8 py-3 text-sm font-medium ' +
            (mode === 'chinese'
              ? 'bg-white text-black'
              : 'bg-white/[0.06] text-white/80 hover:bg-white/[0.1]')
          }
        >
          {t('Chinese', '中文')}
        </button>
        <button
          type="button"
          onClick={() => onContinue('en')}
          className={
            'rounded-xl px-8 py-3 text-sm font-medium ' +
            (mode === 'english'
              ? 'bg-white text-black'
              : 'bg-white/[0.06] text-white/80 hover:bg-white/[0.1]')
          }
        >
          {t('English', '英语')}
        </button>
        <button
          type="button"
          onClick={() => setMode('other')}
          className={
            'rounded-xl px-8 py-3 text-sm font-medium ' +
            (mode === 'other'
              ? 'bg-white text-black'
              : 'bg-white/[0.06] text-white/80 hover:bg-white/[0.1]')
          }
        >
          {t('Other', '其他')}
        </button>
      </div>

      {mode === 'other' && (
        <div className="mt-4 flex w-full flex-col items-start gap-3">
          <input
            autoFocus
            value={other}
            onChange={(e) => setOther(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && trimmed.length > 0) onContinue(trimmed)
            }}
            placeholder={t('Spanish, Portuguese, Japanese…', '西班牙语、葡萄牙语、日语…')}
            className="glass-subtle w-72 rounded-lg px-4 py-3 text-sm text-white/90 placeholder:text-white/30 focus:outline-none focus:ring-1 focus:ring-white/30"
          />
          <button
            type="button"
            onClick={() => onContinue(trimmed)}
            disabled={trimmed.length === 0}
            className="rounded-xl bg-white px-8 py-3 text-sm font-medium text-black transition-opacity hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50"
          >
            {t('Save language', '保存语言')}
          </button>
        </div>
      )}
    </StepScaffold>
  )
}
