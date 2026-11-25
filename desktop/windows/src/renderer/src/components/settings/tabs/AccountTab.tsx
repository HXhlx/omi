import { useState } from 'react'
import { User } from 'lucide-react'
import { getPreferences, setPreferences } from '../../../lib/preferences'
import { setDisplayName } from '../../../lib/userProfile'
import { toast } from '../../../lib/toast'
import { SettingRow } from '../SettingRow'
import { t } from '../../../lib/i18n'

export function AccountTab(): React.JSX.Element {
  const prefs = getPreferences()
  const [name, setName] = useState(prefs.displayName ?? '')

  // Transcription language moved to Settings → Transcription (Mac parity); this
  // row now owns only the display name.
  const saveProfile = (): void => {
    setPreferences({ displayName: name.trim() })
    void setDisplayName(name.trim()).catch(() => toast(t('Name sync failed', '名字同步失败'), { tone: 'warn' }))
    toast(t('Profile saved', '资料已保存'), { tone: 'success' })
  }

  return (
    <>
      <SettingRow
        icon={User}
        title={t('Profile', '个人资料')}
        subtitle={t('Your display name.', '你的显示名称。')}
        keywords="name profile display"
      >
        <div className="space-y-3">
          <input
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder={t('Your name', '你的名字')}
            className="glass-subtle w-full rounded-lg px-4 py-3 text-sm text-text-secondary focus:outline-none"
          />
          <button onClick={saveProfile} className="btn-ghost">
            {t('Save', '保存')}
          </button>
        </div>
      </SettingRow>
    </>
  )
}
