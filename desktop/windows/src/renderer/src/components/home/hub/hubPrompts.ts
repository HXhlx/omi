// Starter prompts under the ask bar. The app has no prompt-suggestions source
// (no server feed, no local generator), so these are the fixed three — swap them
// for the feed the day one exists.
// LOCAL ADAPT (XiaoWo): the CLICKED text is what gets sent, so on the zh UI the
// suggestions themselves must be Chinese — an English chip sending an English
// question would answer in English on a Chinese assistant. Test mode keeps the
// upstream strings (unit tests key off them).
import { isZhUi } from '../../../lib/i18n'

const HUB_SUGGESTIONS_EN = [
  'What should I focus on today to achieve my goals?',
  'What did I spend my time on this week?',
  "What's the highest-leverage thing I can do next?"
]

const HUB_SUGGESTIONS_ZH = [
  '为了达成目标，我今天该专注做什么？',
  '这周我的时间都花在了哪里？',
  '接下来做什么最有价值？'
]

export const HUB_SUGGESTIONS = isZhUi() ? HUB_SUGGESTIONS_ZH : HUB_SUGGESTIONS_EN
