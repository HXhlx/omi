import { useEffect, useState } from 'react'
import { StepScaffold } from './StepScaffold'
import { t } from '../../lib/i18n'
import { getPreferences } from '../../lib/preferences'
import { DEFAULT_OVERLAY_ACCELERATOR, acceleratorToTokens } from '../../lib/overlayShortcut'
import macsImg from '../../assets/macs.png'

type AskDemoStepProps = {
  stepIndex: number
  totalSteps: number
  onContinue: () => void
  onSkip?: () => void
}

/**
 * Onboarding demo step: the user is invited to type "Which computer should I
 * buy?" in the floating bar; Omi's "answer" — a Mac comparison image — is shown
 * as the payoff. The image renders unconditionally (with a mount fade-in) so it
 * can never be held hostage to the floating-bar event firing; Continue is always
 * available so the step can't dead-end.
 */
export function AskDemoStep({
  stepIndex,
  totalSteps,
  onContinue,
  onSkip
}: AskDemoStepProps): React.JSX.Element {
  // Drives the enter transition: mount with the "from" classes, then flip to
  // "to" on the next frame so the fade+slide animates.
  const [revealed, setRevealed] = useState(false)

  // The bar is PARKED at this point (it hid after the voice step's last hold),
  // and the step copy says "type in the floating bar" without ever saying HOW
  // to bring it up — a first-run user (and the product owner, independently)
  // stalled here looking for the bar. The summon is the gesture steps 9-10
  // just taught, so say it again with the user's actual shortcut, in the same
  // kbd style the voice step uses.
  const hotkeyTokens = acceleratorToTokens(
    getPreferences().overlayShortcut ?? DEFAULT_OVERLAY_ACCELERATOR
  )

  useEffect(() => {
    // The bar should already be enabled/warm from earlier steps; ensure it.
    window.omiOverlay?.setEnabled(true)
    const id = requestAnimationFrame(() => setRevealed(true))
    return () => cancelAnimationFrame(id)
  }, [])

  return (
    <StepScaffold
      stepIndex={stepIndex}
      totalSteps={totalSteps}
      title={t(
        'Type in the floating bar “Which computer should I buy?”',
        '在悬浮栏输入“我该买哪台电脑？”'
      )}
      align="center"
      widthClassName="max-w-[820px]"
      onContinue={onContinue}
      onSkip={onSkip}
    >
      <div className="mt-4 flex min-h-[260px] w-full items-center justify-center">
        <img
          src={macsImg}
          alt={t("Omi's answer: a comparison of Mac models", '小蜗的回答：Mac 机型对比')}
          onError={(e) => console.error('[AskDemoStep] macs.png failed to load', e)}
          className={
            'w-full rounded-2xl shadow-2xl ring-1 ring-white/10 transition-all duration-500 ease-out ' +
            (revealed ? 'translate-y-0 opacity-100' : 'translate-y-4 opacity-0')
          }
        />
      </div>

      {/* How to actually summon the bar this step asks the user to type into. */}
      <div className="mt-2 flex w-full max-w-[420px] flex-col items-center gap-3">
        <div className="flex items-center gap-2">
          <span className="mr-1 text-sm font-medium text-white/50">
            {t('First press', '先按')}
          </span>
          {hotkeyTokens.map((token, i) => (
            <kbd
              key={`${token}-${i}`}
              className="flex h-[40px] min-w-[40px] items-center justify-center rounded-lg bg-white/[0.08] px-2.5 text-xs font-semibold text-white/85"
            >
              {token}
            </kbd>
          ))}
        </div>
        <p className="text-center text-sm text-white/55">
          {t(
            'A quick press summons the bar — click the pill to expand it, then type. (Hold instead to talk.)',
            '快速按一下唤出悬浮栏 —— 点击胶囊展开后输入。（长按则是说话。）'
          )}
        </p>
      </div>
    </StepScaffold>
  )
}
