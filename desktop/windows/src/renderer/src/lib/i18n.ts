// LOCAL ADAPT (omi_local_changes pattern): minimal UI-localization helper for
// the Windows desktop client on this machine. The upstream app has no i18n
// framework; this machine runs the UI in Chinese by translating strings at
// their render sites via t('English', '中文').
//
// Rules:
//  - `en` is ALWAYS the upstream source string — it doubles as the key and the
//    test-mode output, so vitest (MODE === 'test', no locale) sees English and
//    upstream unit tests keep passing unmodified.
//  - Set VITE_OMI_UI_LOCALE=en in .env to flip this machine back to English.
//  - Only wrap user-visible text (JSX text, placeholder, aria-label, title).
//    Strings that double as logic (route names, filter keys, enum values) stay
//    English in comparisons; wrap only at the render boundary.

type Locale = 'en' | 'zh'

const LOCALE: Locale = import.meta.env.VITE_OMI_UI_LOCALE === 'en' ? 'en' : 'zh'

export function isZhUi(): boolean {
  return import.meta.env.MODE !== 'test' && LOCALE === 'zh'
}

export function t(en: string, zh: string): string {
  if (!isZhUi()) return en
  return zh
}
