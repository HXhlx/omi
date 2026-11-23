import type { Memory } from '../hooks/useMemories'
import { t } from './i18n'
import { APP_INDEX_TAG } from './memoryCleanup'
import { SCREEN_TAG } from './screenTag'

export type MemorySource =
  'screen' | 'file-index' | 'gmail' | 'sticky-notes' | 'manual' | 'conversation' | 'app' | 'unknown'

const sourceLabels: Record<MemorySource, string> = {
  screen: t('Screen capture', '屏幕截图'),
  'file-index': t('File index', '文件索引'),
  gmail: t('Gmail import', 'Gmail 导入'),
  'sticky-notes': t('Sticky Notes', '便笺'),
  manual: t('Added by you', '你添加的'),
  conversation: t('Conversation', '对话'),
  app: t('App', '应用'),
  unknown: t('Origin not recorded', '来源未记录')
}

export function memorySource(memory: Memory): MemorySource {
  const tags = memory.tags ?? []
  const evidenceTypes = memory.evidence?.flatMap((evidence) =>
    evidence.source_type ? [evidence.source_type] : []
  )
  if (tags.includes(SCREEN_TAG)) return 'screen'
  if (tags.includes(APP_INDEX_TAG)) return 'file-index'
  if (tags.some((tag) => tag.startsWith('gmail/'))) return 'gmail'
  if (tags.some((tag) => tag.startsWith('sticky_notes/'))) return 'sticky-notes'
  if (evidenceTypes?.includes('manual')) return 'manual'
  if (
    evidenceTypes?.some((type) =>
      ['conversation', 'chat', 'chat_exchange', 'transcript', 'voice_transcript'].includes(type)
    )
  ) {
    return 'conversation'
  }
  if (evidenceTypes?.includes('screenshot_ocr')) return 'screen'
  if (
    evidenceTypes?.some(
      (type) =>
        type === 'api' ||
        type === 'developer_api' ||
        type === 'mcp' ||
        type.startsWith('integration:')
    )
  ) {
    return 'app'
  }
  if (memory.manually_added || memory.category === 'manual') return 'manual'
  if (memory.conversation_id) return 'conversation'
  if (memory.app_id) return 'app'
  return 'unknown'
}

export function memorySourceLabel(memory: Memory): string {
  return sourceLabels[memorySource(memory)]
}
