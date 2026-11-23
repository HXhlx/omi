// Settings → Advanced → "AI profile" subsection. Mac parity with
// aiUserProfileSubsection (SettingsContentView): shows the synthesized "about you"
// profile with its last-updated date + data-source count, and lets the user
// Regenerate, inline-Edit (Save), or Delete it. The backend owns the profile
// (generation, daily cadence, storage); this UI is a thin driver over the
// aiProfile:* IPCs, which proxy GET / POST refresh / PATCH / DELETE on
// /v1/users/ai-profile.
//
// There is deliberately NO enable toggle here — the backend generates for every
// user, so this is preview/CRUD only.
import { useEffect, useState } from 'react'
import { UserRound } from 'lucide-react'
import { SettingRow } from '../SettingRow'
import { t } from '../../../lib/i18n'
import type { AiUserProfile } from '../../../../../shared/types'
import {
  AI_PROFILE_FALLBACK as FALLBACK,
  aiProfileErrorMessage
} from '../../../lib/aiProfileMessages'

export function AiProfileCard(): React.JSX.Element {
  const [record, setRecord] = useState<AiUserProfile | null>(null)
  const [loading, setLoading] = useState(true)
  const [generating, setGenerating] = useState(false)
  const [error, setError] = useState<string | null>(null)

  // Inline edit state.
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState('')
  const [saving, setSaving] = useState(false)

  const [confirmingDelete, setConfirmingDelete] = useState(false)

  useEffect(() => {
    void window.omi
      .aiProfileGet()
      .then((r) => {
        if (r.ok) {
          setRecord(r.value)
        } else {
          setRecord(null)
          setError(aiProfileErrorMessage(r.code, 'load'))
        }
      })
      .catch(() => setRecord(null))
      .finally(() => setLoading(false))
  }, [])

  const regenerate = async (): Promise<void> => {
    if (generating) return
    setGenerating(true)
    setError(null)
    try {
      // The backend synthesizes synchronously (~10-40 s).
      const r = await window.omi.aiProfileRefresh()
      if (r.ok) {
        setRecord(r.value)
        setEditing(false)
      } else {
        setError(aiProfileErrorMessage(r.code, 'generate'))
      }
    } catch {
      setError(FALLBACK.generate)
    } finally {
      setGenerating(false)
    }
  }

  const startEdit = (): void => {
    if (!record) return
    setDraft(record.profileText)
    setEditing(true)
    setError(null)
  }

  const saveEdit = async (): Promise<void> => {
    if (!record || saving) return
    setSaving(true)
    setError(null)
    try {
      const r = await window.omi.aiProfileEdit(draft)
      if (r.ok) {
        // The backend's copy is the source of truth after the write.
        setRecord(r.value)
        setEditing(false)
      } else {
        setError(aiProfileErrorMessage(r.code, 'save'))
      }
    } catch {
      setError(FALLBACK.save)
    } finally {
      setSaving(false)
    }
  }

  const remove = async (): Promise<void> => {
    if (!record) return
    setError(null)
    try {
      const r = await window.omi.aiProfileDelete()
      if (r.ok) setRecord(null)
      else setError(aiProfileErrorMessage(r.code, 'delete'))
    } catch {
      setError(FALLBACK.delete)
    } finally {
      setConfirmingDelete(false)
    }
  }

  const updatedAt = record ? (record.generatedAt ?? record.refreshedAt) : null

  return (
    <SettingRow
      icon={UserRound}
      title={t('AI profile', 'AI 画像')}
      subtitle={t(
        'A synthesized “about you” summary Omi builds from your memories, tasks, goals, and conversations — used to personalize proactive help.',
        '小蜗从你的记忆、任务、目标和对话中合成的「关于你」摘要 —— 用于个性化主动帮助。'
      )}
      keywords="ai profile about you dossier synthesized personalize regenerate"
    >
      <div className="space-y-3">
        {loading ? (
          <p className="text-sm text-text-tertiary">{t('Loading…', '加载中…')}</p>
        ) : !record ? (
          // Empty state.
          <div className="space-y-3">
            <p className="text-sm text-text-tertiary">{t('No profile yet.', '还没有画像。')}</p>
            <button
              onClick={regenerate}
              disabled={generating}
              className="btn-primary px-4 py-2 disabled:opacity-40"
            >
              {generating ? t('Generating…', '生成中…') : t('Generate Now', '立即生成')}
            </button>
          </div>
        ) : editing ? (
          // Inline edit.
          <div className="space-y-3">
            <textarea
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              rows={8}
              className="input-field resize-none"
            />
            <div className="flex items-center gap-2">
              <button
                onClick={saveEdit}
                disabled={saving}
                className="btn-primary px-4 py-2 disabled:opacity-40"
              >
                {saving ? t('Saving…', '保存中…') : t('Save', '保存')}
              </button>
              <button
                onClick={() => {
                  setEditing(false)
                  setError(null)
                }}
                disabled={saving}
                className="btn-ghost disabled:opacity-40"
              >
                {t('Cancel', '取消')}
              </button>
            </div>
          </div>
        ) : (
          // Preview.
          <div className="space-y-3">
            <div className="glass-subtle max-h-56 select-text overflow-y-auto whitespace-pre-wrap rounded-lg px-4 py-3 text-sm text-text-secondary">
              {record.profileText}
            </div>
            <p className="text-xs text-text-tertiary">
              {updatedAt !== null && (
                <>{t('Last updated:', '上次更新：')} {new Date(updatedAt).toLocaleDateString()} · </>
              )}
              {t(`Data sources: ${record.dataSourcesUsed} items`, `数据来源：${record.dataSourcesUsed} 项`)}
            </p>
            <div className="flex flex-wrap items-center gap-2">
              <button
                onClick={regenerate}
                disabled={generating}
                className="btn-ghost disabled:opacity-40"
              >
                {generating ? t('Regenerating…', '重新生成中…') : t('Regenerate', '重新生成')}
              </button>
              <button
                onClick={startEdit}
                disabled={generating}
                className="btn-ghost disabled:opacity-40"
              >
                {t('Edit', '编辑')}
              </button>
              {confirmingDelete ? (
                <>
                  <button
                    onClick={remove}
                    className="text-sm font-medium text-red-400 hover:text-red-300"
                  >
                    {t('Confirm delete', '确认删除')}
                  </button>
                  <button
                    onClick={() => setConfirmingDelete(false)}
                    className="btn-ghost disabled:opacity-40"
                  >
                    {t('Cancel', '取消')}
                  </button>
                </>
              ) : (
                <button
                  onClick={() => setConfirmingDelete(true)}
                  disabled={generating}
                  className="text-sm font-medium text-red-400 hover:text-red-300 disabled:opacity-40"
                >
                  {t('Delete', '删除')}
                </button>
              )}
            </div>
          </div>
        )}

        {error && <p className="text-sm text-amber-400">{error}</p>}
      </div>
    </SettingRow>
  )
}
