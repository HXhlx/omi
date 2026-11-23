// LOCAL ADAPT (XiaoWo): render-only zh labels for the two onboarding starter
// goals (GoalStep's GOAL_ZH). Stored titles stay English (wire value / React
// key); only visible text is localized. Shared by Home chips, Goals page and
// QuickGoalsWidget so a goal reads the same everywhere.
import { t } from './i18n'

const STARTER_GOAL_ZH: Record<string, string> = {
  'Be more productive and focused every day': '每天更高效、更专注',
  'Make meaningful progress on my projects': '在项目上取得实质性进展'
}

export function goalLabel(title: string): string {
  return t(title, STARTER_GOAL_ZH[title] ?? title)
}
