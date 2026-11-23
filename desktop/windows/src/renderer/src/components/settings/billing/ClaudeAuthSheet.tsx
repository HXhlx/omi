import { useEffect, useState } from 'react'
import { t } from '../../../lib/i18n'
import { Modal } from '../../ui/Modal'
import { onClaudeSignIn, dismissClaudeSignIn, OMI_PRICING_URL } from '../../../lib/claudeSignIn'

// "Upgrade to Omi Pro" sheet — Windows port of macOS ClaudeAuthSheet. Shown
// ONLY by the mid-turn `auth_required` event (Claude Code's token rejected
// during a chat turn) via beginClaudeSignIn(), which also launches the parallel
// Claude OAuth — matching macOS's `.sheet(isPresented: $chatProvider
// .isClaudeAuthRequired)`. It is NOT tied to the Settings → Agents sign-in
// button (that does plain OAuth, no upsell). Completing the parallel sign-in
// auto-closes it and grants Claude with no purchase. Copy/intent match macOS
// verbatim; the primary CTA opens omi.me/pricing. Neutral white primary, no
// purple (INV-UI-1). Mounted once at the app root.
export function ClaudeAuthSheet(): React.JSX.Element {
  const [open, setOpen] = useState(false)

  useEffect(() => onClaudeSignIn((s) => setOpen(s.open)), [])

  const onUpgrade = (): void => {
    dismissClaudeSignIn()
    void window.omi.openExternalUrl(OMI_PRICING_URL)
  }

  return (
    <Modal
      open={open}
      onOpenChange={(next) => {
        if (!next) dismissClaudeSignIn()
      }}
      title={t('Upgrade to Omi Pro', '升级到小蜗 Pro')}
      size="sm"
      footer={
        <>
          <button
            onClick={dismissClaudeSignIn}
            className="rounded-2xl px-4 py-2 text-sm font-medium text-text-tertiary transition hover:text-text-secondary"
          >
            {t('Cancel', '取消')}
          </button>
          <button
            onClick={onUpgrade}
            className="rounded-2xl bg-white px-4 py-2 text-sm font-semibold text-black transition hover:opacity-90"
          >
            {t('Upgrade to Omi Pro', '升级到小蜗 Pro')}
          </button>
        </>
      }
    >
      <p className="text-text-secondary">{t('Unlock Omi Pro', '解锁小蜗 Pro')}</p>
      <p className="mt-2 text-text-tertiary">
        {t('Your browser will open to the Omi Pro checkout. After subscribing, return to omi.', '浏览器将打开小蜗 Pro 的订阅页面。订阅完成后回到小蜗即可。')}
      </p>
      <p className="mt-3 text-xs text-text-tertiary">{t('Complete sign-in in your browser…', '请在浏览器中完成登录…')}</p>
    </Modal>
  )
}
