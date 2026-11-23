import { useEffect, useState } from 'react'
import { StickyNote, Inbox } from 'lucide-react'
import { toast } from '../../../lib/toast'
import { readAndExtractStickyNotes, importStickyMemories } from '../../../lib/stickyNotesImport'
import { toastImportTally } from '../../../lib/importToast'
import { useMemories } from '../../../hooks/useMemories'
import { GMAIL_SESSION_ENABLED } from '../../../lib/gmailSessionFeatureFlag'
import { auth } from '../../../lib/firebase'
import { SettingRow } from '../SettingRow'
import { t } from '../../../lib/i18n'
import type { GmailSessionStatus } from '../../../../../shared/types'

export function IntegrationsTab(): React.JSX.Element {
  const { memories, refresh } = useMemories()

  // --- Sticky Notes ---
  const [stickyReading, setStickyReading] = useState(false)
  const [stickyImporting, setStickyImporting] = useState(false)
  const [stickyMemories, setStickyMemories] = useState<string[] | null>(null)
  const [stickyProfile, setStickyProfile] = useState('')

  const readSticky = async (): Promise<void> => {
    if (stickyReading || stickyImporting) return
    setStickyReading(true)
    setStickyMemories(null)
    setStickyProfile('')
    try {
      const outcome = await readAndExtractStickyNotes(memories.map((m) => m.content))
      if (outcome.status === 'unavailable')
        toast(t('No Sticky Notes found on this PC', '这台电脑上没有找到便笺'), { tone: 'warn' })
      else if (outcome.status === 'error')
        toast(t('Could not read Sticky Notes', '无法读取便笺'), { tone: 'error', body: outcome.error })
      else if (outcome.status === 'empty')
        toast(
          outcome.reason === 'no-notes'
            ? t('No note text to import', '没有可导入的便笺文本')
            : t('No new memories found in your notes', '便笺中没有发现新记忆'),
          { tone: 'warn' }
        )
      else {
        setStickyMemories(outcome.memories)
        setStickyProfile(outcome.profile)
      }
    } catch (e) {
      toast(t('Could not read Sticky Notes', '无法读取便笺'), { tone: 'error', body: (e as Error).message })
    } finally {
      setStickyReading(false)
    }
  }

  const importSticky = async (): Promise<void> => {
    if (!stickyMemories || stickyMemories.length === 0 || stickyImporting) return
    setStickyImporting(true)
    const tally = await importStickyMemories(stickyMemories, stickyProfile)
    setStickyImporting(false)
    toastImportTally(tally)
    if (tally.ok > 0) await refresh()
    if (!tally.failed) {
      setStickyMemories(null)
      setStickyProfile('')
    }
  }

  // --- Gmail (session): Option B. Sign into Google once inside an Omi-owned window;
  // we replay Gmail's web endpoints against that persisted session (no OAuth scopes). ---
  const [gmailStatus, setGmailStatus] = useState<GmailSessionStatus>({ connected: false })
  const [gmailBusy, setGmailBusy] = useState(false)
  const [gmailFetching, setGmailFetching] = useState(false)

  useEffect(() => {
    if (!GMAIL_SESSION_ENABLED) return
    window.omi
      .gmailSessionStatus()
      .then(setGmailStatus)
      .catch(() => {})
  }, [])

  const connectGmail = async (): Promise<void> => {
    if (gmailBusy) return
    setGmailBusy(true)
    try {
      // Pre-select the account: pass the signed-in Omi user's Google email so Google
      // lands on "Continue as <account>" instead of an empty identifier field.
      const next = await window.omi.gmailSessionConnect(auth.currentUser?.email ?? undefined)
      setGmailStatus(next)
      if (next.connected) toast(t('Gmail connected', 'Gmail 已连接'), { tone: 'success' })
      else if (next.message) toast(t('Gmail not connected', 'Gmail 未连接'), { tone: 'warn', body: next.message })
    } catch (e) {
      toast(t('Could not connect Gmail', '无法连接 Gmail'), { tone: 'error', body: (e as Error).message })
    } finally {
      setGmailBusy(false)
    }
  }

  const fetchGmail = async (): Promise<void> => {
    if (gmailFetching) return
    setGmailFetching(true)
    try {
      const res = await window.omi.gmailSessionFetch('newer_than:7d', 25)
      if (res.ok) {
        toast(t(`Read ${res.emails.length} recent emails`, `已读取 ${res.emails.length} 封近期邮件`), {
          tone: 'success'
        })
      } else {
        toast(t('Could not read Gmail', '无法读取 Gmail'), { tone: 'warn', body: res.error })
        // Network-probe the session (not the cheap cookie check): a stale-but-present
        // session verifies as disconnected, flipping the row back to a Connect prompt.
        setGmailStatus(await window.omi.gmailSessionVerify())
      }
    } catch (e) {
      toast(t('Could not read Gmail', '无法读取 Gmail'), { tone: 'error', body: (e as Error).message })
    } finally {
      setGmailFetching(false)
    }
  }

  const disconnectGmail = async (): Promise<void> => {
    if (gmailBusy) return
    setGmailBusy(true)
    try {
      setGmailStatus(await window.omi.gmailSessionDisconnect())
      toast(t('Gmail disconnected', 'Gmail 已断开'), { tone: 'success' })
    } catch (e) {
      toast(t('Could not disconnect', '无法断开'), { tone: 'error', body: (e as Error).message })
    } finally {
      setGmailBusy(false)
    }
  }

  return (
    <>
      <SettingRow
        icon={StickyNote}
        title={t('Windows Sticky Notes', 'Windows 便笺')}
        subtitle={t(
          'Reads your Sticky Notes locally and saves durable facts as memories. Your notes are never uploaded — only the synthesized facts.',
          '在本地读取便笺并把持久事实存为记忆。便笺绝不上传 —— 只上传合成的事实。'
        )}
        keywords="sticky notes import integration"
        control={
          <div className="flex items-center gap-2">
            <button
              onClick={readSticky}
              disabled={stickyReading || stickyImporting}
              className="btn-ghost disabled:opacity-40"
            >
              {stickyReading ? t('Reading…', '读取中…') : t('Read notes', '读取便笺')}
            </button>
            {stickyMemories && stickyMemories.length > 0 && (
              <button
                onClick={importSticky}
                disabled={stickyImporting}
                className="btn-primary px-4 py-2 disabled:opacity-40"
              >
                {stickyImporting
                  ? t('Importing…', '导入中…')
                  : t(`Import ${stickyMemories.length} memories`, `导入 ${stickyMemories.length} 条记忆`)}
              </button>
            )}
          </div>
        }
      >
        {stickyProfile && (
          <p className="glass-subtle mb-2 rounded-lg px-4 py-3 text-sm italic text-text-tertiary">
            {stickyProfile}
          </p>
        )}
        {stickyMemories && stickyMemories.length > 0 && (
          <ul className="glass-subtle max-h-40 overflow-y-auto rounded-lg px-4 py-3 text-sm text-text-tertiary">
            {stickyMemories.map((m, i) => (
              <li key={i} className="py-0.5">
                • {m}
              </li>
            ))}
          </ul>
        )}
      </SettingRow>

      {GMAIL_SESSION_ENABLED && (
        <SettingRow
          icon={Inbox}
          dot={gmailStatus.connected ? 'on' : 'off'}
          title={t('Gmail (session)', 'Gmail（会话）')}
          subtitle={
            gmailStatus.connected
              ? t('Connected — reads recent mail through your signed-in Google session. No OAuth scopes; sign-in stays inside Omi.', '已连接 —— 通过你登录的 Google 会话读取近期邮件。无 OAuth 授权域；登录留在小蜗内。')
              : gmailStatus.message ||
                t('Sign into Google once inside Omi, then read recent mail without restricted-scope OAuth.', '在小蜗内登录一次 Google，即可读取近期邮件，无需受限 OAuth 授权域。')
          }
          keywords="gmail session email inbox connect integration"
          control={
            gmailStatus.connected ? (
              <div className="flex items-center gap-2">
                <button
                  onClick={fetchGmail}
                  disabled={gmailFetching}
                  className="btn-primary px-4 py-2 disabled:opacity-40"
                >
                  {gmailFetching ? t('Reading…', '读取中…') : t('Fetch recent', '读取近期')}
                </button>
                <button
                  onClick={disconnectGmail}
                  disabled={gmailBusy}
                  className="btn-ghost disabled:opacity-40"
                >
                  {t('Disconnect', '断开')}
                </button>
              </div>
            ) : (
              <button
                onClick={connectGmail}
                disabled={gmailBusy}
                className="btn-ghost disabled:opacity-40"
              >
                {gmailBusy ? t('Connecting…', '连接中…') : t('Connect', '连接')}
              </button>
            )
          }
        />
      )}
    </>
  )
}
