import { useEffect, useState } from 'react'
import { Download, Upload, Wrench, FolderSearch, Network, RotateCcw } from 'lucide-react'
import { auth } from '../../../lib/firebase'
import { toast } from '../../../lib/toast'
import { type MemorySource } from '../../../lib/memoryExtract'
import {
  extractPasteMemories,
  importPasteMemories,
  toastForExtractResult
} from '../../../lib/pasteImport'
import { toastImportTally } from '../../../lib/importToast'
import { buildLocalGraph } from '../../../lib/kgSynthesis'
import {
  summarizeMemories,
  appIndexMemoryIds,
  type MemoryBreakdown
} from '../../../lib/memoryCleanup'
import { fetchAllMemories } from '../../../lib/memoriesBulk'
import { runMemoryExport } from '../../../lib/memoryExport'
import { useMemories, type Memory } from '../../../hooks/useMemories'
import { resetOnboarding } from '../../../lib/preferences'
import { SettingRow } from '../SettingRow'
import { t } from '../../../lib/i18n'
import { IntegrationsTab } from './IntegrationsTab'
import { DeveloperKeysSection } from './DeveloperKeysSection'
import { AiProfileCard } from './AiProfileCard'
import type { ExportMemory, FileIndexStatus, LocalKGStatus } from '../../../../../shared/types'

export function AdvancedTab(): React.JSX.Element {
  const { memories, refresh } = useMemories()

  // --- File indexing ---
  const [fileIndex, setFileIndex] = useState<FileIndexStatus | null>(null)
  const [scanning, setScanning] = useState(false)
  useEffect(() => {
    window.omi
      .indexFilesStatus()
      .then(setFileIndex)
      .catch(() => setFileIndex(null))
  }, [])
  const rescan = async (): Promise<void> => {
    if (scanning) return
    setScanning(true)
    try {
      setFileIndex(await window.omi.indexFilesScan())
      toast(t('File index updated', '文件索引已更新'), { tone: 'success' })
      void buildLocalGraph().catch(() => {})
    } catch (e) {
      toast(t('File indexing failed', '文件索引失败'), { tone: 'error', body: (e as Error).message })
    } finally {
      setScanning(false)
    }
  }

  // --- Knowledge graph ---
  const [kgStatus, setKgStatus] = useState<LocalKGStatus | null>(null)
  const [rebuildingKg, setRebuildingKg] = useState(false)
  useEffect(() => {
    window.omi
      .kgStatus()
      .then(setKgStatus)
      .catch(() => setKgStatus(null))
  }, [])
  const rebuildKg = async (): Promise<void> => {
    if (rebuildingKg) return
    setRebuildingKg(true)
    try {
      setKgStatus(await buildLocalGraph())
      toast(t('Knowledge graph rebuilt', '知识图谱已重建'), { tone: 'success' })
    } catch (e) {
      toast(t('Knowledge graph rebuild failed', '知识图谱重建失败'), { tone: 'error', body: (e as Error).message })
    } finally {
      setRebuildingKg(false)
    }
  }

  // --- Import memories ---
  const [dump, setDump] = useState('')
  const [source, setSource] = useState<MemorySource>('chatgpt')
  const [parsed, setParsed] = useState<string[] | null>(null)
  const [profile, setProfile] = useState('')
  const [extracting, setExtracting] = useState(false)
  const [importing, setImporting] = useState(false)

  const extractDump = async (): Promise<void> => {
    if (extracting) return
    setExtracting(true)
    setProfile('')
    try {
      const r = await extractPasteMemories(
        dump,
        source,
        memories.map((m) => m.content)
      )
      setParsed(r.memories)
      setProfile(r.profile)
      toastForExtractResult(r)
    } catch (e) {
      toast(t('Could not extract memories', '无法提取记忆'), { tone: 'error', body: (e as Error).message })
    } finally {
      setExtracting(false)
    }
  }

  const importMemories = async (): Promise<void> => {
    if (!parsed || parsed.length === 0 || importing) return
    setImporting(true)
    const tally = await importPasteMemories(parsed)
    setImporting(false)
    toastImportTally(tally)
    if (tally.ok > 0) await refresh()
    if (!tally.failed) {
      setDump('')
      setParsed(null)
      setProfile('')
    }
  }

  // --- Export memories ---
  const [notionToken, setNotionToken] = useState('')
  const [notionPage, setNotionPage] = useState('')
  const [exporting, setExporting] = useState(false)
  const toExportMemories = (): ExportMemory[] =>
    memories.map((m) => ({
      content: m.content,
      category: m.category ?? null,
      createdAt: m.created_at
    }))

  const runExport = async (target: 'obsidian' | 'file' | 'notion'): Promise<void> => {
    if (exporting) return
    if (memories.length === 0) {
      toast(t('No memories to export yet', '还没有可导出的记忆'), { tone: 'warn' })
      return
    }
    if (target === 'notion' && (!notionToken.trim() || !notionPage.trim())) {
      toast(t('Enter your Notion token and parent page ID', '请输入 Notion 令牌和父页面 ID'), { tone: 'warn' })
      return
    }
    setExporting(true)
    try {
      const r = await runMemoryExport(
        target,
        toExportMemories(),
        target === 'notion'
          ? { token: notionToken.trim(), parentPageId: notionPage.trim() }
          : undefined
      )
      if (!r.canceled) {
        toast(t(`Exported ${r.count} memories`, `已导出 ${r.count} 条记忆`), {
          tone: 'success',
          body: r.location
        })
      }
    } catch (e) {
      toast(t('Export failed', '导出失败'), { tone: 'error', body: (e as Error).message })
    } finally {
      setExporting(false)
    }
  }

  // --- Memory maintenance ---
  const [memBreakdown, setMemBreakdown] = useState<MemoryBreakdown | null>(null)
  const [memAllMemories, setMemAllMemories] = useState<Memory[]>([])
  const [memAuditing, setMemAuditing] = useState(false)
  const [memDeleting, setMemDeleting] = useState(false)
  const [memDeleteProgress, setMemDeleteProgress] = useState(0)

  const auditMemories = async (): Promise<void> => {
    if (memAuditing || memDeleting) return
    setMemAuditing(true)
    try {
      const all = await fetchAllMemories()
      setMemAllMemories(all)
      setMemBreakdown(summarizeMemories(all))
    } catch (e) {
      toast(t('Could not load memories', '无法加载记忆'), { tone: 'error', body: (e as Error).message })
    } finally {
      setMemAuditing(false)
    }
  }

  const deleteAppIndexMemories = async (): Promise<void> => {
    const ids = appIndexMemoryIds(memAllMemories)
    if (ids.length === 0 || memDeleting) return
    if (
      !window.confirm(
        t(
          `Permanently delete ${ids.length} app/file-index memories? This cannot be undone.`,
          `永久删除 ${ids.length} 条应用/文件索引记忆？此操作不可撤销。`
        )
      )
    )
      return
    const token = await auth.currentUser?.getIdToken(true)
    if (!token) {
      toast(t('Sign in required to delete memories', '删除记忆需要登录'), { tone: 'warn' })
      return
    }
    setMemDeleting(true)
    setMemDeleteProgress(0)

    // Main-process bulk delete via DELETE /v3/memories/batch: one gate hold per
    // 100-id chunk instead of N single deletes colliding on the account-wide
    // destructive-operation gate (409) and the 60/hour single-delete limiter.
    const offProgress = window.omi.onMemoriesDeleteProgress((p) => setMemDeleteProgress(p.deleted))
    try {
      const result = await window.omi.memoriesBulkDelete({ token, ids })
      toast(t(`Deleted ${result.deleted} of ${ids.length} memories`, `已删除 ${result.deleted}/${ids.length} 条记忆`), {
        tone: result.failed ? 'warn' : 'success',
        body: result.failed
          ? t(
              `${result.failed} failed. Analyze again to retry.`,
              `${result.failed} 条失败。重新分析后可重试。`
            )
          : undefined
      })
    } catch (e) {
      toast(t('Delete failed', '删除失败'), { tone: 'error', body: (e as Error).message })
    } finally {
      offProgress()
      setMemDeleting(false)
    }
    await refresh()
    await auditMemories()
  }

  const replayOnboarding = (): void => {
    resetOnboarding()
    window.location.reload()
  }

  return (
    <>
      <SettingRow
        icon={Download}
        title={t('Import memories', '导入记忆')}
        subtitle={t(
          'Paste a ChatGPT/Claude “everything you remember about me” reply; Omi extracts distinct, durable facts.',
          '粘贴 ChatGPT/Claude 的「你记得关于我的一切」回复；小蜗会提取独立、持久的事实。'
        )}
        keywords="import chatgpt claude memories paste extract"
      >
        <div className="space-y-3">
          <div className="flex items-center gap-2">
            <span className="text-sm text-text-tertiary">{t('Exported from', '导出来源')}</span>
            {(['chatgpt', 'claude'] as const).map((s) => (
              <button
                key={s}
                onClick={() => setSource(s)}
                className={`rounded-md px-3 py-1 text-sm ${source === s ? 'btn-primary' : 'btn-ghost'}`}
              >
                {s === 'chatgpt' ? 'ChatGPT' : 'Claude'}
              </button>
            ))}
          </div>
          <textarea
            value={dump}
            onChange={(e) => {
              setDump(e.target.value)
              setParsed(null)
              setProfile('')
            }}
            rows={5}
            placeholder={t('Paste the assistant’s full reply here…', '把助手的完整回复粘贴到这里…')}
            className="input-field resize-none"
          />
          <div className="flex items-center gap-2">
            <button
              onClick={extractDump}
              disabled={!dump.trim() || extracting || importing}
              className="btn-ghost disabled:opacity-40"
            >
              {extracting ? t('Extracting…', '提取中…') : t('Extract memories', '提取记忆')}
            </button>
            {parsed && parsed.length > 0 && (
              <button
                onClick={importMemories}
                disabled={importing}
                className="btn-primary px-4 py-2 disabled:opacity-40"
              >
                {importing
                  ? t('Importing…', '导入中…')
                  : t(`Import ${parsed.length} memories`, `导入 ${parsed.length} 条记忆`)}
              </button>
            )}
          </div>
          {profile && (
            <p className="glass-subtle rounded-lg px-4 py-3 text-sm italic text-text-tertiary">
              {profile}
            </p>
          )}
          {parsed && parsed.length > 0 && (
            <ul className="glass-subtle max-h-40 overflow-y-auto rounded-lg px-4 py-3 text-sm text-text-tertiary">
              {parsed.map((m, i) => (
                <li key={i} className="py-0.5">
                  • {m}
                </li>
              ))}
            </ul>
          )}
        </div>
      </SettingRow>

      <SettingRow
        icon={Upload}
        title={t('Export memories', '导出记忆')}
        subtitle={t(
          `Export your ${memories.length} memories as Markdown (Obsidian, a plain file, or Notion).`,
          `把 ${memories.length} 条记忆导出为 Markdown（Obsidian、纯文件或 Notion）。`
        )}
        keywords="export obsidian notion file markdown"
      >
        <div className="space-y-3">
          <div className="flex flex-wrap gap-2">
            <button
              onClick={() => runExport('obsidian')}
              disabled={exporting}
              className="btn-ghost disabled:opacity-40"
            >
              {t('Obsidian vault…', 'Obsidian 库…')}
            </button>
            <button
              onClick={() => runExport('file')}
              disabled={exporting}
              className="btn-ghost disabled:opacity-40"
            >
              {t('Plain file…', '纯文件…')}
            </button>
          </div>
          <div className="border-t border-white/5 pt-3">
            <p className="mb-2 text-sm text-text-tertiary">
              {t('Notion — paste an internal-integration token and a page ID it can access.', 'Notion —— 粘贴内部集成令牌和它可访问的页面 ID。')}
            </p>
            <input
              value={notionToken}
              onChange={(e) => setNotionToken(e.target.value)}
              placeholder={t('Notion integration token (secret_…)', 'Notion 集成令牌（secret_…）')}
              className="glass-subtle mb-2 w-full rounded-lg px-4 py-3 text-sm text-text-secondary focus:outline-none"
            />
            <input
              value={notionPage}
              onChange={(e) => setNotionPage(e.target.value)}
              placeholder={t('Parent page ID', '父页面 ID')}
              className="glass-subtle mb-2 w-full rounded-lg px-4 py-3 text-sm text-text-secondary focus:outline-none"
            />
            <button
              onClick={() => runExport('notion')}
              disabled={exporting}
              className="btn-ghost disabled:opacity-40"
            >
              {exporting ? t('Exporting…', '导出中…') : t('Export to Notion', '导出到 Notion')}
            </button>
          </div>
        </div>
      </SettingRow>

      <SettingRow
        icon={Wrench}
        title={t('Memory maintenance', '记忆维护')}
        subtitle={t(
          'Find and remove legacy app/file-index memories (these belong in the knowledge graph, not memories). Analyze is read-only.',
          '查找并移除遗留的应用/文件索引记忆（它们属于知识图谱，不是记忆）。分析是只读的。'
        )}
        keywords="maintenance cleanup delete app file index memories audit"
      >
        <div className="space-y-3">
          <div className="flex items-center gap-2">
            <button
              onClick={auditMemories}
              disabled={memAuditing || memDeleting}
              className="btn-ghost disabled:opacity-40"
            >
              {memAuditing ? t('Analyzing…', '分析中…') : t('Analyze memories', '分析记忆')}
            </button>
            {memBreakdown && memBreakdown.appIndexCount > 0 && (
              <button
                onClick={deleteAppIndexMemories}
                disabled={memDeleting || memAuditing}
                className="btn-primary px-4 py-2 disabled:opacity-40"
              >
                {memDeleting
                  ? t(`Deleting ${memDeleteProgress}/${memBreakdown.appIndexCount}…`, `删除中 ${memDeleteProgress}/${memBreakdown.appIndexCount}…`)
                  : t(`Delete ${memBreakdown.appIndexCount} app/file memories`, `删除 ${memBreakdown.appIndexCount} 条应用/文件记忆`)}
              </button>
            )}
          </div>
          {memBreakdown && (
            <div className="glass-subtle rounded-lg px-4 py-3 text-sm text-text-tertiary">
              <p className="mb-2 text-text-secondary">
                {t(`${memBreakdown.total} total memories`, `共 ${memBreakdown.total} 条记忆`)} ·{' '}
                <span className="text-text-primary">{memBreakdown.appIndexCount}</span>{' '}
                {t('app/file-index matches', '条应用/文件索引匹配')}
              </p>
              {memBreakdown.appIndexCount > 0 && (
                <ul className="mb-3 max-h-32 overflow-y-auto">
                  {memBreakdown.appIndexSamples.map((s, i) => (
                    <li key={i} className="py-0.5">
                      • {s}
                    </li>
                  ))}
                </ul>
              )}
              <p className="mb-1 text-text-secondary">{t('Breakdown by tag (not deleted):', '按标签分组（不删除）：')}</p>
              <ul className="max-h-40 overflow-y-auto">
                {memBreakdown.groups.map((g) => (
                  <li key={g.key} className="py-0.5">
                    <span className="text-text-primary">{g.count}</span> — {g.key}
                    {g.samples[0] ? (
                      <span className="opacity-60"> · e.g. “{g.samples[0]}”</span>
                    ) : null}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </div>
      </SettingRow>

      {/* Integrations (Sticky Notes, Google) live under Advanced. */}
      <IntegrationsTab />

      {/* AI profile — Mac renders this as the aiUserProfileSubsection in Advanced. */}
      <AiProfileCard />

      {/* Developer API Keys (BYOK) — Mac renders this as an Advanced subsection. */}
      <DeveloperKeysSection />

      <SettingRow
        icon={FolderSearch}
        title={t('File indexing', '文件索引')}
        subtitle={
          fileIndex
            ? t(
                `${fileIndex.filesIndexed.toLocaleString()} items indexed${
                  fileIndex.lastRunAt
                    ? ` · last run ${new Date(fileIndex.lastRunAt).toLocaleString()}`
                    : ''
                }`,
                `已索引 ${fileIndex.filesIndexed.toLocaleString()} 项${
                  fileIndex.lastRunAt
                    ? ` · 上次运行 ${new Date(fileIndex.lastRunAt).toLocaleString()}`
                    : ''
                }`
              )
            : t('Indexes file names/metadata locally (contents never read or uploaded).', '在本地索引文件名/元数据（绝不读取或上传内容）。')
        }
        keywords="file index scan rescan local"
        control={
          <button onClick={rescan} disabled={scanning} className="btn-ghost disabled:opacity-40">
            {scanning ? t('Indexing…', '索引中…') : t('Re-scan now', '立即重新扫描')}
          </button>
        }
      />

      <SettingRow
        icon={Network}
        title={t('Knowledge graph', '知识图谱')}
        subtitle={
          kgStatus
            ? t(
                `${kgStatus.nodeCount.toLocaleString()} nodes · ${kgStatus.edgeCount.toLocaleString()} relationships${
                  kgStatus.lastBuiltAt
                    ? ` · last built ${new Date(kgStatus.lastBuiltAt).toLocaleString()}`
                    : ''
                }`,
                `${kgStatus.nodeCount.toLocaleString()} 个节点 · ${kgStatus.edgeCount.toLocaleString()} 条关系${
                  kgStatus.lastBuiltAt
                    ? ` · 上次构建 ${new Date(kgStatus.lastBuiltAt).toLocaleString()}`
                    : ''
                }`
              )
            : t('A local graph of your projects, tech, people, and apps — used to ground chat answers.', '项目、技术、人物和应用的本地图谱 —— 用于让聊天回答有据可依。')
        }
        keywords="knowledge graph rebuild kg nodes"
        control={
          <button
            onClick={rebuildKg}
            disabled={rebuildingKg}
            className="btn-ghost disabled:opacity-40"
          >
            {rebuildingKg ? t('Rebuilding…', '重建中…') : t('Rebuild now', '立即重建')}
          </button>
        }
      />

      <SettingRow
        icon={RotateCcw}
        title={t('Replay onboarding', '重玩引导')}
        subtitle={t('Run the startup wizard again from the beginning.', '从头再跑一遍启动向导。')}
        keywords="onboarding wizard replay reset"
        control={
          <button onClick={replayOnboarding} className="btn-ghost">
            {t('Replay', '重玩')}
          </button>
        }
      />
    </>
  )
}
