import { useState } from 'react'
import { StepScaffold } from './StepScaffold'
import { t } from '../../lib/i18n'

type HowDidYouHearStepProps = {
  stepIndex: number
  totalSteps: number
  onContinue: (source: string) => void
  onBack: () => void
  aside?: React.ReactNode
}

// Same set the macOS desktop app offers (canonical casing matches the values it
// reports to PostHog), in the order requested for the Windows wizard.
const SOURCES = [
  'Other',
  'Colleague',
  'Product Hunt',
  'Article',
  'Friend',
  'Event',
  'AI chat',
  'YouTube',
  'Search engine',
  'Newsletter',
  'Podcast',
  'Social media'
]

// Render-only zh labels. SOURCES itself stays English: those exact strings are
// what `onContinue(source)` reports to PostHog, what `selected === source`
// compares, and the React keys.
const SOURCE_ZH: Record<string, string> = {
  Other: '其他',
  Colleague: '同事',
  'Product Hunt': 'Product Hunt',
  Article: '文章',
  Friend: '朋友',
  Event: '活动',
  'AI chat': 'AI 聊天',
  YouTube: 'YouTube',
  'Search engine': '搜索引擎',
  Newsletter: '邮件通讯',
  Podcast: '播客',
  'Social media': '社交媒体'
}

export function HowDidYouHearStep({
  stepIndex,
  totalSteps,
  onContinue,
  onBack,
  aside
}: HowDidYouHearStepProps): React.JSX.Element {
  const [selected, setSelected] = useState<string | null>(null)

  const pick = (source: string): void => {
    if (selected) return
    setSelected(source)
    // Brief highlight before advancing, mirroring the desktop app's 0.25s delay.
    setTimeout(() => onContinue(source), 250)
  }

  return (
    <StepScaffold
      stepIndex={stepIndex}
      totalSteps={totalSteps}
      eyebrow={t('QUICK QUESTION', '小问题')}
      title={t('How did you hear about Omi?', '你从哪里听说 Omi？')}
      align="left"
      onBack={onBack}
      aside={aside}
    >
      <div className="flex flex-wrap gap-2.5">
        {SOURCES.map((source) => (
          <button
            key={source}
            type="button"
            onClick={() => pick(source)}
            className={
              'rounded-xl px-5 py-2.5 text-sm font-medium ' +
              (selected === source
                ? 'bg-white text-black'
                : 'bg-white/[0.06] text-white/80 hover:bg-white/[0.1]')
            }
          >
            {t(source, SOURCE_ZH[source] ?? source)}
          </button>
        ))}
      </div>
    </StepScaffold>
  )
}
