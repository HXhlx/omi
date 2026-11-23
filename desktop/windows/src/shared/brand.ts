// LOCAL ADAPT (XiaoWo): single source of truth for the assistant's display name.
// The upstream product is "Omi"; this machine ships the XiaoWo (小蜗) accessibility
// assistant built on the OMI desktop shell. Both the main process (tray, window
// titles) and the renderer (wordmark, chat rows, onboarding copy) read from here
// so the brand can never drift between surfaces.
//
// `BRAND_EN` stays the upstream name for test-mode expectations and English
// locale; `isZhBrand()` mirrors lib/i18n.ts's gate (test mode = upstream English,
// VITE_OMI_UI_LOCALE=en flips this machine back).

export const BRAND_EN = 'Omi'
export const BRAND_ZH = '小蜗'

export function isZhBrand(): boolean {
  return import.meta.env.MODE !== 'test' && import.meta.env.VITE_OMI_UI_LOCALE !== 'en'
}

/** The assistant display name for the active locale ("Omi" / "小蜗"). */
export function brandName(): string {
  return isZhBrand() ? BRAND_ZH : BRAND_EN
}
