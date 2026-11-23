import { Zap } from 'lucide-react'
import { getPreferences, setPreferences } from '../../lib/preferences'
import { PermissionStep } from './PermissionStep'
import { t } from '../../lib/i18n'

type AutomationPermissionStepProps = {
  stepIndex: number
  totalSteps: number
  aside?: React.ReactNode
  onContinue: () => void
  onBack?: () => void
  onSkip?: () => void
}

export function AutomationPermissionStep({
  stepIndex,
  totalSteps,
  aside,
  onContinue,
  onBack,
  onSkip
}: AutomationPermissionStepProps): React.JSX.Element {
  // Automation has no OS permission prompt (Windows UIA needs no grant) — enabling it
  // is a local opt-in that records consent, so what `checkGranted` reads below is that
  // consent, not an OS state. useChat's action-planner pre-step gates on this preference
  // (alongside the OMI_AUTOMATION env kill-switch), so flipping it on here is what
  // actually lets Omi take real UI actions in your apps.
  const enableAutomation = async (): Promise<void> => {
    setPreferences({ automationConsentedAt: Date.now() })
  }

  // The consent already recorded (a resumed or repeated onboarding). Reading it keeps the
  // card honest — "Enabled", not "Not enabled yet" — and, because a detected state never
  // auto-advances, the user still confirms with Continue rather than watching the step
  // flash by.
  const isConsented = async (): Promise<boolean> =>
    typeof getPreferences().automationConsentedAt === 'number'

  return (
    <PermissionStep
      stepIndex={stepIndex}
      totalSteps={totalSteps}
      aside={aside}
      eyebrow={t('PERMISSION', '权限')}
      title={t('Let Omi act when asked', '按你的要求执行操作')}
      subtitle={t('Automation lets Omi take actions for you', '自动化让小蜗替你执行操作')}
      icon={<Zap className="h-5 w-5 text-white/60" />}
      cardLabel={t('Automation', '自动化')}
      statusText={{
        idle: t('Not enabled yet', '尚未启用'),
        waiting: t('Enabling', '正在启用'),
        granted: t('Enabled', '已启用'),
        denied: t("Couldn't enable", '无法启用')
      }}
      buttonLabel={{
        idle: t('Enable', '启用'),
        waiting: t('Enabling', '正在启用'),
        granted: t('Enabled', '已启用'),
        denied: t('Try again', '重试')
      }}
      onActivate={enableAutomation}
      checkGranted={isConsented}
      onContinue={onContinue}
      onBack={onBack}
      onSkip={onSkip}
    />
  )
}
