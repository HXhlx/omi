import { CreditCard, Loader2, RefreshCw } from 'lucide-react'
import { BillingCard } from './BillingCard'
import {
  resolvePlanTitle,
  currentPlanSubtitle,
  currentPlanPeriodText,
  hasPaidSubscription
} from '../../../lib/billing'
import type { UserSubscriptionResponse } from '../../../lib/omiApi.generated'
import { t } from '../../../lib/i18n'

/**
 * Current-plan card (AccountBilling "planusage.current"): plan title + billing
 * detail, a renew/access-ends caption, and a Manage (paid → Stripe portal) or
 * Refresh (free) action.
 */
export function CurrentPlanCard(props: {
  sub: UserSubscriptionResponse
  portalBusy: boolean
  refreshing: boolean
  onManage: () => void
  onRefresh: () => void
}): React.JSX.Element {
  const { sub, portalBusy, refreshing, onManage, onRefresh } = props
  const subscription = sub.subscription
  const paid = hasPaidSubscription(subscription)
  const periodText = currentPlanPeriodText(subscription)

  return (
    <BillingCard
      icon={CreditCard}
      title={resolvePlanTitle(subscription, sub.available_plans)}
      subtitle={currentPlanSubtitle(subscription, sub.available_plans)}
      trailing={
        paid ? (
          <button
            onClick={onManage}
            disabled={portalBusy}
            className="btn-ghost disabled:opacity-50"
          >
            {portalBusy ? <Loader2 className="h-4 w-4 animate-spin" /> : null}
            {t('Manage', '管理')}
          </button>
        ) : (
          <button
            onClick={onRefresh}
            disabled={refreshing}
            className="btn-ghost disabled:opacity-50"
          >
            <RefreshCw className={`h-4 w-4 ${refreshing ? 'animate-spin' : ''}`} />
            {t('Refresh', '刷新')}
          </button>
        )
      }
    >
      {periodText ? <div className="text-sm text-text-tertiary">{periodText}</div> : null}
      {subscription.features?.includes('byok') ? (
        <div className="space-y-1 text-sm text-text-tertiary">
          <div>{t('Chat and AI: BYOK supported — configure keys in Developer settings', '聊天与 AI：支持 BYOK —— 在开发者设置中配置密钥')}</div>
          <div>
            {sub.transcription_allowance?.reason === 'byok'
              ? t('Transcription: Deepgram BYOK', '转写：Deepgram BYOK')
              : sub.transcription_allowance &&
                  sub.transcription_allowance.reason !== 'allowance_unavailable' &&
                  sub.transcription_allowance.reason !== 'usage_invalid'
                ? t('Transcription: Omi plan allowance', '转写：套餐额度')
                : t('Transcription allowance unavailable — refresh to check', '转写额度不可用 —— 刷新查看')}
          </div>
        </div>
      ) : null}
    </BillingCard>
  )
}
