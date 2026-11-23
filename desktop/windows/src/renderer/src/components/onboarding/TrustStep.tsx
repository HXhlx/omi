import { Monitor, Mic, Sparkles, type LucideIcon } from 'lucide-react'
import { StepScaffold } from './StepScaffold'
import { t } from '../../lib/i18n'

type TrustStepProps = {
  stepIndex: number
  totalSteps: number
  onContinue: () => void
  onBack: () => void
}

// The macOS desktop app's "Read the source code" button opens the public repo.
const SOURCE_URL = 'https://github.com/BasedHardware/omi'

const PERMISSIONS: { icon: LucideIcon; title: string; detail: string }[] = [
  {
    icon: Monitor,
    title: 'Screen + recording',
    detail: 'Build context for what you’re working on.'
  },
  {
    icon: Mic,
    title: 'Microphone',
    detail: 'Capture voice notes and meeting context.'
  },
  {
    icon: Sparkles,
    title: 'Take actions in your apps',
    detail: 'See the active window and, with your approval each time, click and type for you.'
  }
]

// Render-only zh labels. The PERMISSIONS entries stay English because each
// `title` doubles as the list's React key.
const PERMISSION_TITLE_ZH: Record<string, string> = {
  'Screen + recording': '屏幕 + 录音',
  Microphone: '麦克风',
  'Take actions in your apps': '在你的应用中执行操作'
}

const PERMISSION_DETAIL_ZH: Record<string, string> = {
  'Build context for what you’re working on.': '为你正在进行的工作建立上下文。',
  'Capture voice notes and meeting context.': '捕捉语音笔记与会议上下文。',
  'See the active window and, with your approval each time, click and type for you.':
    '查看当前活动窗口，并在每次经你确认后替你点击和输入。'
}

export function TrustStep({
  stepIndex,
  totalSteps,
  onContinue,
  onBack
}: TrustStepProps): React.JSX.Element {
  return (
    <StepScaffold
      stepIndex={stepIndex}
      totalSteps={totalSteps}
      eyebrow={t('BEFORE WE CONTINUE', '继续之前')}
      title={t("I'm going to ask you for a few permissions", '我需要向你申请几个权限')}
    >
      <div className="w-full">
        <p className="text-center text-sm leading-relaxed text-white">
          {t(
            'Omi is open source and private by design. During setup, we’ll ask you for these permissions to understand your work and help in the right places.',
            '小蜗开源且以隐私为核心设计。在设置过程中，我们会申请这些权限，以了解你的工作并在合适的地方提供帮助。'
          )}
        </p>

        <div className="mt-6 flex flex-col gap-3">
          {PERMISSIONS.map(({ icon: Icon, title, detail }) => (
            <div
              key={title}
              className="flex w-full items-center gap-4 rounded-xl bg-white/[0.06] px-5 py-3 text-left"
            >
              <Icon className="h-6 w-6 shrink-0 text-white/80" strokeWidth={1.75} />
              <div>
                <p className="text-sm font-semibold text-white">
                  {t(title, PERMISSION_TITLE_ZH[title] ?? title)}
                </p>
                <p className="mt-0.5 text-xs text-white/60">
                  {t(detail, PERMISSION_DETAIL_ZH[detail] ?? detail)}
                </p>
              </div>
            </div>
          ))}
        </div>

        <div className="mt-6 flex items-center justify-center gap-2.5">
          <button
            type="button"
            onClick={onBack}
            className="rounded-lg bg-black px-5 py-2 text-sm font-medium text-white ring-1 ring-white/15 transition-colors hover:bg-white/5"
          >
            {t('Back', '返回')}
          </button>
          <button
            type="button"
            onClick={onContinue}
            className="rounded-lg bg-white px-5 py-2 text-sm font-medium text-black transition-opacity hover:opacity-90"
          >
            {t('Continue', '继续')}
          </button>
          <button
            type="button"
            onClick={() => window.open(SOURCE_URL)}
            className="rounded-lg bg-black px-5 py-2 text-sm font-medium text-white ring-1 ring-white/15 transition-colors hover:bg-white/5"
          >
            {t('Read the source code', '阅读源代码')}
          </button>
        </div>
      </div>
    </StepScaffold>
  )
}
