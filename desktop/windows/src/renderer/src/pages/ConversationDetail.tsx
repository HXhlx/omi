import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import {
  ArrowLeft,
  Check,
  ChevronDown,
  Copy,
  Link2,
  Loader2,
  PanelRightClose,
  PanelRightOpen,
  Pencil,
  RefreshCw,
  Sparkles,
  Trash2
} from 'lucide-react'
import { omiApi } from '../lib/apiClient'
import { t } from '../lib/i18n'
import { deleteCloudConversation } from '../lib/conversations/mutations'
import { isLocalConversationId, isPendingConversationId } from '../lib/conversationId'
import { invalidateConversationsCache } from '../lib/pageCache'
import { toast } from '../lib/toast'
import type {
  App as AppEntry,
  Conversation as ServerConversation,
  Person,
  TranscriptSegment
} from '../lib/omiApi.generated'
import type { ChatMessage, ConversationFolder } from '../../../shared/types'
import { Markdown } from '../components/Markdown'
import {
  noteTranscriptIDs,
  presentableNoteText,
  presentableNoteTitle
} from '@omi/note-shared/note-sources.mjs'
import { Spinner } from '../components/ui/Spinner'
import { ModalShell } from '../components/conversations/ModalShell'
import { MoveToFolderMenu } from '../components/conversations/MoveToFolderMenu'
import { NameSpeakerModal } from '../components/conversations/NameSpeakerModal'
import { TranscriptDrawer } from '../components/conversations/TranscriptDrawer'
import { fetchPeople } from '../lib/conversations/people'
import { fetchFolders } from '../lib/conversations/folders'
import { friendlyConversationError } from '../lib/conversations/detailErrors'
import { buildTranscriptText } from '../lib/conversations/transcript'
import {
  getConversationShareLink,
  moveConversationToFolder,
  reprocessConversation,
  setConversationTitle
} from '../lib/conversations/mutations'
import {
  POLL_INTERVAL_MS,
  isEnriching,
  shouldStopPolling
} from '../lib/conversations/detailPolling'
import {
  conversationDuration,
  displayCategory,
  formatDuration,
  formatWhen
} from '../lib/conversations/detailFormat'

// Mac's ConversationDetailView, ported: a FULL PAGE (not a modal/drawer) that
// replaces the list, with a 450px transcript drawer that slides in from the right.
//
// Deliberate deviations from Mac, both approved:
//  - Action items stay INTERACTIVE here. Mac renders them display-only; Windows
//    already had a working toggle and keeps it (positional contract:
//    PATCH /v1/conversations/{id}/action-items {items_idx, values}).
//  - Speaker naming never fabricates a segment id. See lib/conversations/speakers.ts.
//
// There is intentionally NO star button in this header — starring lives on the
// list row only (Mac parity).

const INSIGHT_COLLAPSE_CHARS = 200

type LocalDisplay = {
  title: string
  subtitle?: string
  transcript?: string
  chatMessages?: ChatMessage[]
}

function Chip({ children }: { children: React.ReactNode }): React.JSX.Element {
  return (
    <span className="flex items-center gap-1.5 rounded-full border border-border bg-white/[0.04] px-2.5 py-1 text-[11px] text-text-tertiary">
      {children}
    </span>
  )
}

function ToolbarButton({
  onClick,
  title,
  disabled,
  children
}: {
  onClick: () => void
  title: string
  disabled?: boolean
  children: React.ReactNode
}): React.JSX.Element {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      title={title}
      aria-label={title}
      className="btn-ghost p-2 disabled:opacity-40"
    >
      {children}
    </button>
  )
}

/** One app-insight card: collapsed past 200 chars, like Mac. */
function InsightCard({
  appName,
  content
}: {
  appName: string
  content: string
}): React.JSX.Element {
  const [expanded, setExpanded] = useState(false)
  const collapsible = content.length > INSIGHT_COLLAPSE_CHARS

  return (
    <div className="surface-card p-4">
      <div className="flex items-start justify-between gap-3">
        <h3 className="text-sm font-medium text-white">{appName}</h3>
        {collapsible && (
          <button
            onClick={() => setExpanded((v) => !v)}
            aria-expanded={expanded}
            title={expanded ? t('Collapse', '收起') : t('Expand', '展开')}
            className="btn-ghost shrink-0 p-1"
          >
            <ChevronDown
              className={`h-4 w-4 transition-transform ${expanded ? 'rotate-180' : ''}`}
            />
          </button>
        )}
      </div>
      <div
        className={`mt-2 text-sm leading-relaxed text-text-secondary ${
          collapsible && !expanded ? 'line-clamp-3' : ''
        }`}
      >
        <Markdown text={content} />
      </div>
    </div>
  )
}

/** Rename dialog — Mac uses an alert with a TextField; Windows uses a centered
 *  modal. Title is a QUERY param on the backend (see mutations.setConversationTitle). */
function RenameModal({
  initial,
  onClose,
  onSave
}: {
  initial: string
  onClose: () => void
  onSave: (title: string) => void
}): React.JSX.Element {
  const [value, setValue] = useState(initial)
  return (
    <ModalShell onClose={onClose} labelledBy="rename-conv-title">
      <form
        onSubmit={(e) => {
          e.preventDefault()
          const next = value.trim()
          if (next) onSave(next)
        }}
      >
        <h2 id="rename-conv-title" className="font-display text-lg font-semibold text-white">
          {t('Edit title', '编辑标题')}
        </h2>
        {/* autoFocus is intentional: the modal only opens on an explicit user action */}
        <input
          autoFocus
          value={value}
          onChange={(e) => setValue(e.target.value)}
          aria-label={t('Conversation title', '对话标题')}
          className="mt-4 w-full rounded-xl border border-white/15 bg-white/[0.04] px-3 py-2 text-sm text-white focus:border-white/40 focus:outline-none"
        />
        <div className="mt-5 flex justify-end gap-2">
          <button type="button" onClick={onClose} className="btn-ghost px-3 py-1.5 text-sm">
            {t('Cancel', '取消')}
          </button>
          <button
            type="submit"
            disabled={!value.trim()}
            className="rounded-lg bg-white px-3 py-1.5 text-sm font-medium text-bg-primary disabled:opacity-40"
          >
            {t('Save', '保存')}
          </button>
        </div>
      </form>
    </ModalShell>
  )
}

/**
 * Remounts the view whenever the conversation changes, so opening a different
 * conversation starts from clean state. Without the key we would have to reset
 * every piece of state synchronously inside the load effect — which is exactly
 * the cascading-render pattern react-hooks warns about.
 */
export function ConversationDetail({
  conversationId
}: {
  conversationId: string
}): React.JSX.Element {
  return <ConversationDetailView key={conversationId} conversationId={conversationId} />
}

function ConversationDetailView({ conversationId }: { conversationId: string }): React.JSX.Element {
  const id = conversationId
  const navigate = useNavigate()
  const isLocal = isLocalConversationId(id)
  const isPending = isPendingConversationId(id)

  const [conv, setConv] = useState<ServerConversation | null>(null)
  useEffect(() => {}, [conv, id])
  const [local, setLocal] = useState<LocalDisplay | null>(null)
  const [error, setError] = useState<string | null>(null)
  // Bumping this re-runs the initial-load effect (Try again after a failed load).
  const [reloadNonce, setReloadNonce] = useState(0)
  const [people, setPeople] = useState<Person[]>([])
  const [folders, setFolders] = useState<ConversationFolder[]>([])
  const [apps, setApps] = useState<AppEntry[]>([])

  const [drawerOpen, setDrawerOpen] = useState(false) // Mac: closed by default
  const [renaming, setRenaming] = useState(false)
  const [naming, setNaming] = useState<TranscriptSegment | null>(null)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [copied, setCopied] = useState<'link' | 'transcript' | null>(null)
  const [reprocessing, setReprocessing] = useState(false)
  const [pickingApp, setPickingApp] = useState(false)

  const pollRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const fetchConversation = useCallback(async (): Promise<ServerConversation> => {
    const r = await omiApi.get<ServerConversation>(`/v1/conversations/${id}`)
    return r.data
  }, [id])

  // Initial load (runs once per conversation — the component is keyed by id).
  // Folder/people lookups are best-effort: a failure there must never blank out
  // the conversation itself.
  useEffect(() => {
    let cancelled = false
    if (isPending) return
    ;(async () => {
      try {
        if (isLocal) {
          const c = await window.omi.getLocalConversation(id)
          if (cancelled) return
          if (!c) {
            // Kept English on purpose: friendlyConversationError() matches the raw
            // message for 'not found', so this string is a logic input, not display.
            setError('Local conversation not found')
            return
          }
          setLocal(
            c.kind === 'chat'
              ? {
                  title: c.title || t('Chat with Omi', '与 Omi 聊天'),
                  subtitle: `${new Date(c.startedAt).toLocaleString()} · ${c.messages?.length ?? 0} ${t('messages', '条消息')}`,
                  chatMessages: c.messages ?? [],
                  transcript: c.transcript
                }
              : {
                  title: c.title || t('Recording', '录音'),
                  subtitle: `${new Date(c.startedAt).toLocaleString()} · ${Math.round(
                    (c.endedAt - c.startedAt) / 1000
                  )}s · ${t('local only', '仅保存在本地')}`,
                  transcript: c.transcript
                }
          )
          return
        }

        const c = await fetchConversation()
        if (cancelled) return
        setConv(c)

        const [ppl, flds] = await Promise.all([
          fetchPeople().catch(() => [] as Person[]),
          fetchFolders().catch(() => [] as ConversationFolder[])
        ])
        if (cancelled) return
        setPeople(ppl)
        setFolders(flds)
      } catch (e) {
        if (!cancelled) setError((e as Error).message)
      }
    })()

    return () => {
      cancelled = true
    }
  }, [id, isLocal, isPending, fetchConversation, reloadNonce])

  // Poll while Omi enriches: 15 attempts, 2s apart, stopping the moment the
  // status leaves `processing`. A self-scheduling timeout (not setInterval) so a
  // slow response can't stack requests.
  useEffect(() => {
    if (!conv || isLocal || !isEnriching(conv)) return

    let cancelled = false
    let attempt = 0

    const tick = async (): Promise<void> => {
      attempt++
      try {
        const next = await fetchConversation()
        if (cancelled) return
        setConv(next)
        if (shouldStopPolling(next.status, attempt)) return
      } catch {
        if (cancelled) return
        if (shouldStopPolling('processing', attempt)) return // still counts against the ceiling
      }
      pollRef.current = setTimeout(tick, POLL_INTERVAL_MS)
    }

    pollRef.current = setTimeout(tick, POLL_INTERVAL_MS)
    return () => {
      cancelled = true
      if (pollRef.current) clearTimeout(pollRef.current)
      pollRef.current = null
    }
    // Re-arms only when the id changes or enrichment starts/stops — not on every
    // `conv` update, which would restart the ladder on each poll.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, isLocal, conv && isEnriching(conv), fetchConversation])

  const segments = useMemo(() => conv?.transcript_segments ?? [], [conv])

  const transcriptText = useMemo(() => {
    if (local) return local.transcript ?? ''
    return buildTranscriptText(segments)
  }, [local, segments])

  const flash = (what: 'link' | 'transcript'): void => {
    setCopied(what)
    setTimeout(() => setCopied((c) => (c === what ? null : c)), 1500)
  }

  const onCopyTranscript = async (): Promise<void> => {
    await navigator.clipboard.writeText(transcriptText)
    flash('transcript')
  }

  const onCopyLink = async (): Promise<void> => {
    try {
      const url = await getConversationShareLink(id)
      await navigator.clipboard.writeText(url)
      flash('link')
    } catch (e) {
      toast(t('Could not copy link', '无法复制链接'), { tone: 'error', body: (e as Error).message })
    }
  }

  const onRename = async (title: string): Promise<void> => {
    setRenaming(false)
    const prev = conv?.structured?.title ?? local?.title ?? ''
    // Optimistic; revert on failure.
    if (conv) setConv({ ...conv, structured: { ...conv.structured, title } })
    else if (local) setLocal({ ...local, title })
    try {
      if (isLocal) await window.omi.updateLocalConversationTitle(id, title)
      else await setConversationTitle(id, title)
      invalidateConversationsCache()
    } catch (e) {
      if (conv) setConv((c) => (c ? { ...c, structured: { ...c.structured, title: prev } } : c))
      else setLocal((l) => (l ? { ...l, title: prev } : l))
      toast(t('Rename failed', '重命名失败'), { tone: 'error', body: (e as Error).message })
    }
  }

  const onDelete = async (): Promise<void> => {
    setConfirmDelete(false)
    try {
      if (isLocal) await window.omi.deleteLocalConversation(id)
      else await deleteCloudConversation(id)
      invalidateConversationsCache()
      toast(t('Conversation deleted', '对话已删除'), { tone: 'info' })
      navigate('/conversations')
    } catch (e) {
      toast(t('Delete failed', '删除失败'), { tone: 'error', body: (e as Error).message })
    }
  }

  const onMoveToFolder = async (folderId: string | null): Promise<void> => {
    if (!conv) return
    const prev = conv.folder_id ?? null
    setConv({ ...conv, folder_id: folderId })
    try {
      await moveConversationToFolder(id, folderId)
      invalidateConversationsCache()
    } catch (e) {
      setConv((c) => (c ? { ...c, folder_id: prev } : c))
      toast(t('Could not move conversation', '无法移动对话'), {
        tone: 'error',
        body: (e as Error).message
      })
    }
  }

  const onReprocess = async (appId?: string): Promise<void> => {
    setPickingApp(false)
    setReprocessing(true)
    try {
      await reprocessConversation(id, appId)
      toast(t('Reprocessing', '重新处理中'), {
        tone: 'info',
        body: t('Omi is regenerating the summary.', 'Omi 正在重新生成摘要。')
      })
      setConv((c) => (c ? { ...c, status: 'processing' } : c))
    } catch (e) {
      toast(t('Reprocess failed', '重新处理失败'), { tone: 'error', body: (e as Error).message })
    } finally {
      setReprocessing(false)
    }
  }

  const openAppPicker = async (): Promise<void> => {
    setPickingApp(true)
    if (apps.length === 0) {
      try {
        const r = await omiApi.get<AppEntry[]>('/v1/apps', { params: { include_reviews: false } })
        setApps(Array.isArray(r.data) ? r.data : [])
      } catch {
        /* the picker degrades to an empty state */
      }
    }
  }

  const refetch = useCallback(async (): Promise<void> => {
    try {
      setConv(await fetchConversation())
    } catch {
      /* keep what we have */
    }
  }, [fetchConversation])

  const onToggleActionItem = async (idx: number): Promise<void> => {
    const items = conv?.structured?.action_items
    const item = items?.[idx]
    if (!conv || !items || !item) return
    const next = !item.completed
    const apply = (v: boolean): void =>
      setConv((c) =>
        c?.structured?.action_items
          ? {
              ...c,
              structured: {
                ...c.structured,
                action_items: c.structured.action_items.map((a, i) =>
                  i === idx ? { ...a, completed: v } : a
                )
              }
            }
          : c
      )
    apply(next)
    // The generated embedded ActionItem model has no `id` (backend/models/structured.py)
    // — hence the narrow rather than a plain property read.
    const itemId = (item as { id?: string }).id
    try {
      if (itemId) {
        // Standalone action item: `completed` is bound as a QUERY param
        // (backend/routers/action_items.py::toggle_action_item_completion) — a JSON
        // body is silently ignored and the missing query param 422s. Embedded items
        // never carry an id today, so this branch is currently unreachable; it is
        // kept (and pinned by a test) so a backend that starts returning ids does
        // not silently regress.
        await omiApi.patch(`/v1/action-items/${itemId}/completed`, null, {
          params: { completed: next }
        })
      } else {
        // Positional contract: SetConversationActionItemsStateRequest takes parallel
        // arrays and addresses items by INDEX, not id.
        await omiApi.patch(`/v1/conversations/${id}/action-items`, {
          items_idx: [idx],
          values: [next]
        })
      }
    } catch (e) {
      apply(!next)
      toast(t('Could not update task', '无法更新任务'), {
        tone: 'error',
        body: (e as Error).message
      })
    }
  }

  // ── Shells ────────────────────────────────────────────────────────────────
  const shell = (body: React.ReactNode, title = t('Conversation', '对话')): React.JSX.Element => (
    <div className="flex h-full flex-col">
      <header className="flex shrink-0 items-center gap-3 px-6 pt-4 pb-3 lg:px-10">
        <button
          onClick={() => navigate('/conversations')}
          className="btn-ghost -ml-1 p-2"
          title={t('Back', '返回')}
          aria-label={t('Back', '返回')}
        >
          <ArrowLeft className="h-5 w-5" />
        </button>
        <h1 className="font-display text-xl font-bold text-white">{title}</h1>
      </header>
      {body}
    </div>
  )

  if (isPending) {
    return shell(
      <div className="flex flex-1 flex-col items-center justify-center gap-3 px-10 text-center">
        <Loader2 className="h-6 w-6 animate-spin text-text-tertiary" aria-hidden />
        <p className="max-w-sm text-sm text-text-tertiary">
          {t(
            'Omi is still processing this conversation. It’ll appear in your list shortly.',
            'Omi 正在处理这段对话，稍后会出现在你的列表中。'
          )}
        </p>
      </div>
    )
  }

  if (error) {
    return shell(
      <div className="flex flex-1 flex-col items-center justify-center gap-4 px-10 py-8 text-center">
        <p className="max-w-sm text-sm text-text-tertiary">{friendlyConversationError(error)}</p>
        <button
          onClick={() => {
            setError(null)
            setReloadNonce((n) => n + 1)
          }}
          className="btn-ghost px-3 py-1.5 text-xs"
        >
          <RefreshCw className="h-3.5 w-3.5" />
          {t('Try again', '重试')}
        </button>
      </div>
    )
  }

  if (local) {
    return shell(
      <div className="flex-1 overflow-y-auto px-6 py-6 lg:px-10">
        <div className="mx-auto max-w-3xl space-y-4">
          <p className="text-sm text-text-tertiary">{local.subtitle}</p>
          <div className="surface-card p-6">
            <div className="mb-4 flex items-center justify-between">
              <h2 className="section-label">
                {local.chatMessages ? t('Messages', '消息') : t('Transcript', '转写')}
              </h2>
              <button onClick={onCopyTranscript} className="btn-ghost px-2.5 py-1 text-[11px]">
                {copied === 'transcript' ? t('Copied', '已复制') : t('Copy', '复制')}
              </button>
            </div>
            {local.chatMessages ? (
              <ul className="space-y-3">
                {local.chatMessages.map((m, i) => (
                  <li
                    key={i}
                    className={
                      m.role === 'user'
                        ? 'glass ml-auto max-w-[85%] rounded-2xl px-4 py-3 text-sm text-white'
                        : 'glass-subtle mr-auto max-w-[85%] rounded-2xl px-4 py-3 text-sm text-text-secondary'
                    }
                  >
                    <div className="mb-1 text-[10px] uppercase tracking-wide text-text-quaternary">
                      {m.role === 'user' ? t('You', '你') : 'Omi'}
                    </div>
                    <div className="whitespace-pre-wrap">{m.content}</div>
                  </li>
                ))}
              </ul>
            ) : (
              <pre className="whitespace-pre-wrap font-body text-sm leading-relaxed text-text-secondary">
                {local.transcript || t('(no transcript)', '（暂无转写内容）')}
              </pre>
            )}
          </div>
        </div>
      </div>,
      local.title
    )
  }

  if (!conv) {
    return shell(
      <div className="flex flex-1 items-center justify-center">
        <Spinner label={t('Loading conversation…', '正在加载对话…')} />
      </div>
    )
  }

  const structured = conv.structured ?? {}
  const title = structured.title || t('Conversation', '对话')
  // Read-time citation repair (contracts/note_citation_contract.json), as on macOS and web:
  // legacy notes can carry `[s01234]` / `Speaker_00` debris. Display only; rename edits `title`.
  const transcriptIDs = noteTranscriptIDs(segments)
  const displayTitle =
    presentableNoteTitle(structured.title, transcriptIDs) || t('Conversation', '对话')
  const overview = presentableNoteText(structured.overview?.trim(), transcriptIDs)
  const actionItems = structured.action_items ?? []
  const insights = (conv.apps_results ?? []).filter((r) => r.content?.trim())
  const enriching = isEnriching(conv)
  const status = conv.status ?? ''
  const duration = conversationDuration(conv)
  const category = displayCategory(conv)
  const appName = (appId: string | null): string =>
    apps.find((a) => a.id === appId)?.name ?? t('App insight', '应用洞察')

  return (
    // Mac's root is an HStack: the content column and the transcript drawer are
    // SIBLINGS, so opening the drawer compresses the column instead of covering
    // the header's action buttons (ConversationDetailView.swift:114-166).
    <div className="flex h-full min-h-0">
      <div className="flex min-w-0 flex-1 flex-col overflow-hidden">
        {/* ── Header / toolbar ─────────────────────────────────────────────── */}
        <header className="shrink-0 px-6 pt-4 pb-3 lg:px-10">
          <div className="flex items-start gap-3">
            <button
              onClick={() => navigate('/conversations')}
              className="btn-ghost -ml-1 mt-0.5 shrink-0 p-2"
              title={t('Back', '返回')}
              aria-label={t('Back', '返回')}
            >
              <ArrowLeft className="h-5 w-5" />
            </button>

            <div className="min-w-0 flex-1">
              <div className="flex min-w-0 items-center gap-2">
                {structured.emoji && (
                  <span className="shrink-0 text-xl" aria-hidden>
                    {structured.emoji}
                  </span>
                )}
                <h1 className="truncate font-display text-xl font-bold tracking-tight text-white">
                  {displayTitle}
                </h1>
                <button
                  onClick={() => setRenaming(true)}
                  className="btn-ghost shrink-0 p-1"
                  title={t('Edit title', '编辑标题')}
                  aria-label={t('Edit title', '编辑标题')}
                >
                  <Pencil className="h-3.5 w-3.5" />
                </button>
                {status && status !== 'completed' && (
                  <span className="badge shrink-0 capitalize">{status.replace(/_/g, ' ')}</span>
                )}
              </div>
              <p className="mt-1 text-xs text-text-tertiary">{formatWhen(conv)}</p>
            </div>

            <div className="flex shrink-0 items-center gap-1.5">
              <button
                onClick={() => setDrawerOpen((v) => !v)}
                className="flex items-center gap-1.5 rounded-full border border-border bg-white/[0.04] px-3 py-1.5 text-xs text-text-secondary transition-colors hover:bg-white/10 hover:text-white"
                aria-expanded={drawerOpen}
              >
                {drawerOpen ? (
                  <PanelRightClose className="h-3.5 w-3.5" />
                ) : (
                  <PanelRightOpen className="h-3.5 w-3.5" />
                )}
                {drawerOpen ? t('Hide Transcript', '隐藏转写') : t('View Transcript', '查看转写')}
              </button>

              <ToolbarButton onClick={onCopyLink} title={t('Copy link', '复制链接')}>
                {copied === 'link' ? <Check className="h-4 w-4" /> : <Link2 className="h-4 w-4" />}
              </ToolbarButton>
              <ToolbarButton onClick={onCopyTranscript} title={t('Copy transcript', '复制转写')}>
                {copied === 'transcript' ? (
                  <Check className="h-4 w-4" />
                ) : (
                  <Copy className="h-4 w-4" />
                )}
              </ToolbarButton>
              {folders.length > 0 && (
                <MoveToFolderMenu
                  folders={folders}
                  currentFolderId={conv.folder_id}
                  onMove={onMoveToFolder}
                />
              )}
              <ToolbarButton
                onClick={() => setConfirmDelete(true)}
                title={t('Delete conversation', '删除对话')}
              >
                <Trash2 className="h-4 w-4" />
              </ToolbarButton>
            </div>
          </div>
        </header>

        {/* ── Body ─────────────────────────────────────────────────────────── */}
        <div className="min-h-0 flex-1 overflow-y-auto px-6 pb-10 lg:px-10">
          <div className="mx-auto max-w-3xl space-y-4">
            {enriching ? (
              <div className="surface-card flex flex-col items-center gap-2 p-8 text-center">
                <Loader2 className="h-5 w-5 animate-spin text-text-tertiary" aria-hidden />
                <p className="text-sm text-white">
                  {t('Processing conversation…', '正在处理对话…')}
                </p>
                <p className="text-xs text-text-tertiary">
                  {t('Generating summary and action items', '正在生成摘要和行动项')}
                </p>
              </div>
            ) : (
              overview && (
                <section className="surface-card p-6">
                  <h2 className="section-label mb-3 flex items-center gap-2">
                    <Sparkles className="h-3.5 w-3.5" aria-hidden />
                    {t('Summary', '摘要')}
                  </h2>
                  <div className="text-sm leading-relaxed text-text-secondary">
                    <Markdown text={overview} />
                  </div>
                </section>
              )
            )}

            {/* Metadata chips */}
            <div className="flex flex-wrap items-center gap-2">
              <Chip>{conv.source ?? 'unknown'}</Chip>
              {duration != null && <Chip>{formatDuration(duration)}</Chip>}
              {category && <Chip>{category}</Chip>}
            </div>

            {insights.length > 0 && (
              <section className="space-y-2">
                <div className="flex items-center justify-between">
                  <h2 className="section-label">{t('App Insights', '应用洞察')}</h2>
                  <button
                    onClick={openAppPicker}
                    disabled={reprocessing}
                    className="btn-ghost px-2.5 py-1 text-[11px] disabled:opacity-40"
                  >
                    {reprocessing ? t('Reprocessing…', '重新处理中…') : t('Reprocess', '重新处理')}
                  </button>
                </div>
                {insights.map((r, i) => (
                  <InsightCard
                    key={r.app_id ?? i}
                    appName={appName(r.app_id)}
                    content={r.content}
                  />
                ))}
              </section>
            )}

            {/* Try with Apps — always rendered */}
            <section className="surface-card p-6">
              <h2 className="section-label mb-3">{t('Try with Apps', '试试应用')}</h2>
              {apps.length === 0 ? (
                <div className="flex items-center justify-between gap-3">
                  <p className="text-xs text-text-tertiary">
                    {t(
                      'Run an Omi app over this conversation for extra insights.',
                      '运行一个 Omi 应用，为这段对话生成更多洞察。'
                    )}
                  </p>
                  <button
                    onClick={openAppPicker}
                    className="shrink-0 rounded-lg border border-border px-3 py-1.5 text-xs text-white transition-colors hover:bg-white/10"
                  >
                    {t('Browse apps', '浏览应用')}
                  </button>
                </div>
              ) : (
                <div className="flex gap-2 overflow-x-auto pb-1">
                  {apps.slice(0, 12).map((a) => (
                    <button
                      key={a.id}
                      onClick={() => onReprocess(a.id)}
                      disabled={reprocessing}
                      className="w-40 shrink-0 rounded-xl border border-border bg-white/[0.04] p-3 text-left transition-colors hover:bg-white/10 disabled:opacity-40"
                    >
                      <p className="truncate text-xs font-medium text-white">{a.name}</p>
                      <p className="mt-0.5 truncate text-[10px] text-text-quaternary">{a.author}</p>
                    </button>
                  ))}
                </div>
              )}
            </section>

            {actionItems.length > 0 && (
              <section className="surface-card p-6">
                <h2 className="section-label mb-3">{t('Action Items', '行动项')}</h2>
                <ul className="space-y-1.5">
                  {actionItems.map((a, i) => (
                    <li key={i} className="flex items-start gap-3 py-1">
                      <button
                        onClick={() => onToggleActionItem(i)}
                        aria-pressed={!!a.completed}
                        title={
                          a.completed
                            ? t('Mark as open', '标记为进行中')
                            : t('Mark as done', '标记为完成')
                        }
                        className={`mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-md border transition-all ${
                          a.completed
                            ? 'border-white/30 bg-white/15 text-white'
                            : 'border-white/20 hover:border-white/45'
                        }`}
                      >
                        {a.completed && <Check className="h-3 w-3" strokeWidth={3} />}
                      </button>
                      <span
                        className={`text-sm leading-relaxed ${
                          a.completed ? 'text-text-quaternary line-through' : 'text-text-secondary'
                        }`}
                      >
                        {presentableNoteText(a.description, transcriptIDs)}
                      </span>
                    </li>
                  ))}
                </ul>
              </section>
            )}
          </div>
        </div>
      </div>

      <TranscriptDrawer
        open={drawerOpen}
        segments={segments}
        people={people}
        onClose={() => setDrawerOpen(false)}
        onNameSpeaker={setNaming}
      />

      {renaming && (
        <RenameModal initial={title} onClose={() => setRenaming(false)} onSave={onRename} />
      )}

      {naming && (
        <NameSpeakerModal
          conversationId={id}
          segments={segments}
          segment={naming}
          people={people}
          onClose={() => setNaming(null)}
          onSaved={refetch}
          onPersonCreated={(p) => setPeople((prev) => [...prev, p])}
        />
      )}

      {pickingApp && (
        <ModalShell onClose={() => setPickingApp(false)} labelledBy="pick-app-title">
          <h2 id="pick-app-title" className="font-display text-lg font-semibold text-white">
            {t('Reprocess with an app', '使用应用重新处理')}
          </h2>
          <div className="mt-4 max-h-[320px] space-y-1.5 overflow-y-auto">
            <button
              onClick={() => onReprocess()}
              className="w-full rounded-xl border border-white/10 bg-white/[0.04] px-3 py-2.5 text-left text-sm text-white hover:bg-white/10"
            >
              {t('Default summary', '默认摘要')}
            </button>
            {apps.map((a) => (
              <button
                key={a.id}
                onClick={() => onReprocess(a.id)}
                className="w-full truncate rounded-xl border border-white/10 bg-white/[0.04] px-3 py-2.5 text-left text-sm text-white hover:bg-white/10"
              >
                {a.name}
              </button>
            ))}
          </div>
        </ModalShell>
      )}

      {confirmDelete && (
        <ModalShell onClose={() => setConfirmDelete(false)} labelledBy="delete-conv-title">
          <h2 id="delete-conv-title" className="font-display text-lg font-semibold text-white">
            {t('Delete conversation?', '删除对话？')}
          </h2>
          <p className="mt-2 text-sm text-text-tertiary">
            {t(
              `“${displayTitle}” will be permanently deleted. This cannot be undone.`,
              `“${displayTitle}”将被永久删除，此操作无法撤销。`
            )}
          </p>
          <div className="mt-5 flex justify-end gap-2">
            <button
              onClick={() => setConfirmDelete(false)}
              className="btn-ghost px-3 py-1.5 text-sm"
            >
              {t('Cancel', '取消')}
            </button>
            <button
              onClick={onDelete}
              className="rounded-lg bg-error px-3 py-1.5 text-sm font-medium text-white"
            >
              {t('Delete', '删除')}
            </button>
          </div>
        </ModalShell>
      )}
    </div>
  )
}
