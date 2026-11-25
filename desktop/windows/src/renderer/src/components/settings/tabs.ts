import {
  Settings as SettingsIcon,
  History,
  ShieldCheck,
  CircleUserRound,
  SlidersHorizontal,
  Brain,
  AudioLines,
  Keyboard,
  Bell,
  Info,
  type LucideIcon
} from 'lucide-react'
// LOCAL ADAPT: settings tab labels render in Chinese on this machine (see lib/i18n.ts).
import { t } from '../../lib/i18n'

export type SettingsTabId =
  | 'general'
  | 'memories'
  | 'agents'
  | 'transcription'
  | 'rewind'
  | 'notifications'
  | 'privacy'
  | 'account'
  | 'plan-usage'
  | 'shortcuts'
  | 'advanced'
  | 'about'

export const SETTINGS_TABS: { id: SettingsTabId; label: string; Icon: LucideIcon }[] = [
  { id: 'general', label: t('General', '通用'), Icon: SettingsIcon },
  { id: 'memories', label: t('Memories', '记忆'), Icon: Brain },
  { id: 'transcription', label: t('Transcription', '转写'), Icon: AudioLines },
  { id: 'rewind', label: t('Rewind', '回顾'), Icon: History },
  { id: 'notifications', label: t('Notifications', '通知'), Icon: Bell },
  { id: 'privacy', label: t('Privacy', '隐私'), Icon: ShieldCheck },
  { id: 'account', label: t('Account', '账户'), Icon: CircleUserRound },
  { id: 'shortcuts', label: t('Shortcuts', '快捷键'), Icon: Keyboard },
  { id: 'advanced', label: t('Advanced', '高级'), Icon: SlidersHorizontal },
  { id: 'about', label: t('About', '关于'), Icon: Info }
]
