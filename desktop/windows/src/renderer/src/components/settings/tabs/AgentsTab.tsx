// Settings → Agents: connect the coding agents Omi can delegate tasks to.
// Claude Code ships built in; OpenClaw, Hermes, and Codex are external CLIs.
// We make those three easy: PATH auto-detection shows whether each CLI is
// installed, a one-click "Connect" fills + saves the known launch command and
// runs the real ACP handshake, install commands are one copy away, and Codex
// gets a paste-your-OpenAI-key lane (validated) so it needs no browser sign-in.
// The raw launch command lives under "Advanced" for power users. "Test" (and
// "Connect") spawn the agent and complete a real ACP handshake, so a green
// check means the command actually works — not just that a string was saved.

import { useEffect, useState } from 'react'
import { Bot, Terminal } from 'lucide-react'
import { SettingRow } from '../SettingRow'
import { t } from '../../../lib/i18n'
import { getPreferences, setPreferences } from '../../../lib/preferences'
import { useCodingAgents } from '../../../hooks/useCodingAgents'
import { CLAUDE_SIGN_IN_FAILED } from '../../../lib/claudeSignIn'
import type {
  AgentDetectionMap,
  CodingAgentAuthStatus,
  CodingAgentId
} from '../../../../../shared/types'

type ExternalAgentId = Exclude<CodingAgentId, 'acp'>

type AgentGuide = {
  description: string
  /** Real shell commands to install the CLI (empty when there's no one-liner). */
  installCommands: string[]
  /** Prose install pointer when there's no install command (e.g. Hermes). */
  installNote?: string
  /** Suggested launch command the Connect button auto-fills + saves. */
  suggestedCommand: string
  docsUrl: string
  /** How to sign in after install (honest — Omi does not automate these logins). */
  authNote: string
  /** Codex exposes an in-app OpenAI API-key lane; the others don't (yet). */
  supportsApiKey?: boolean
}

const EXTERNAL_AGENT_GUIDES: Record<ExternalAgentId, AgentGuide> = {
  openclaw: {
    description: t('Open-source AI coding assistant with its own gateway and model routing.', '开源 AI 编程助手，自带网关和模型路由。'),
    installCommands: ['npm install -g openclaw@latest'],
    suggestedCommand: 'openclaw acp',
    docsUrl: 'https://docs.openclaw.ai/install',
    authNote: t('After installing, sign in: run `openclaw onboard` in a terminal.', '安装后登录：在终端运行 `openclaw onboard`。')
  },
  hermes: {
    description: t("Nous Research's Hermes agent, connected over its ACP server mode.", 'Nous Research 的 Hermes 智能体，通过其 ACP 服务模式连接。'),
    installCommands: [],
    installNote: t('Install the Hermes CLI from its documentation.', '按 Hermes 文档安装 CLI。'),
    suggestedCommand: 'hermes acp',
    docsUrl: 'https://hermes-agent.nousresearch.com/docs',
    authNote: t('After installing, sign in: run `hermes login` in a terminal.', '安装后登录：在终端运行 `hermes login`。')
  },
  codex: {
    description: t("OpenAI's Codex agent, driven through the official codex-acp bridge.", 'OpenAI 的 Codex 智能体，通过官方 codex-acp 桥接驱动。'),
    installCommands: ['npm install -g @openai/codex'],
    suggestedCommand: 'npx -y @agentclientprotocol/codex-acp',
    docsUrl: 'https://github.com/agentclientprotocol/codex-acp',
    authNote: t('Sign in with `codex login`, or add your OpenAI API key below.', '用 `codex login` 登录，或在下方填入 OpenAI API 密钥。'),
    supportsApiKey: true
  }
}

type TestState = { running: boolean; verdict?: 'ok' | 'failed'; detail?: string }

type ClaudeAuthUi = { status: CodingAgentAuthStatus | null; busy: boolean; error?: string }

type CodexKeyUi = {
  hasKey: boolean
  input: string
  saving: boolean
  result?: { ok: boolean; msg: string }
}

export function AgentsTab(): React.JSX.Element {
  const { agents, refresh } = useCodingAgents()
  const [commands, setCommands] = useState<Partial<Record<ExternalAgentId, string>>>(
    () => getPreferences().agentCommands ?? {}
  )
  const [tests, setTests] = useState<Partial<Record<CodingAgentId, TestState>>>({})
  const [claudeAuth, setClaudeAuth] = useState<ClaudeAuthUi>({ status: null, busy: false })
  const [detection, setDetection] = useState<Partial<AgentDetectionMap>>({})
  const [advancedOpen, setAdvancedOpen] = useState<Partial<Record<ExternalAgentId, boolean>>>({})
  const [copied, setCopied] = useState<Partial<Record<ExternalAgentId, boolean>>>({})
  const [codexKey, setCodexKey] = useState<CodexKeyUi>({ hasKey: false, input: '', saving: false })

  const refreshClaudeAuth = (): void => {
    void window.omi
      .codingAgentAuthStatus()
      .then((status) => setClaudeAuth((a) => ({ ...a, status })))
      .catch(() => {})
  }

  const refreshDetection = (): void => {
    void window.omi
      .codingAgentDetect()
      .then(setDetection)
      .catch(() => {})
  }

  const refreshCodexKey = (): void => {
    void window.omi
      .codingAgentCodexKeyStatus()
      .then((s) => setCodexKey((k) => ({ ...k, hasKey: s.hasKey })))
      .catch(() => {})
  }

  // Load the Claude Code sign-in state on mount, and re-check whenever a
  // delegated task reports it needs auth (so the row flips to "Sign in" the
  // moment the user's token is rejected mid-task). Also PATH-detect the external
  // CLIs and load the Codex key status once.
  useEffect(() => {
    refreshClaudeAuth()
    refreshDetection()
    refreshCodexKey()
    return window.omi.onCodingAgentEvent((event) => {
      if (event.type === 'auth_required' && event.adapterId === 'acp') refreshClaudeAuth()
    })
  }, [])

  const signInToClaude = (): void => {
    setClaudeAuth((a) => ({ ...a, busy: true, error: undefined }))
    setTests((t) => ({ ...t, acp: { running: false } }))
    // Connecting the coding agent is a plain OAuth (Mac parity) — launch the
    // Claude Code browser sign-in directly, with NO upsell sheet. The
    // "Upgrade to Omi Pro" ClaudeAuthSheet is reserved for the mid-turn
    // auth_required event (see claudeSignIn.ts), so a Pro user connecting here
    // is never paywalled. Reflect the resulting status / surface a failure.
    void window.omi
      .codingAgentStartAuth()
      .then((r) =>
        setClaudeAuth({ status: r.status, busy: false, error: r.ok ? undefined : r.error })
      )
      .catch(() =>
        setClaudeAuth({
          status: { connected: false, expiresAt: null },
          busy: false,
          error: CLAUDE_SIGN_IN_FAILED
        })
      )
  }

  const signOutOfClaude = (): void => {
    void window.omi
      .codingAgentSignOut()
      .then((status) => {
        setClaudeAuth({ status, busy: false })
        setTests((t) => ({ ...t, acp: { running: false } }))
      })
      .catch(() => {})
  }

  const saveCommand = (id: ExternalAgentId): void => {
    const trimmed = commands[id]?.trim()
    const next = { ...(getPreferences().agentCommands ?? {}) }
    if (trimmed) next[id] = trimmed
    else delete next[id]
    setPreferences({ agentCommands: next })
    setTests((t) => ({ ...t, [id]: {} }))
    refresh()
  }

  const runTest = (id: CodingAgentId): void => {
    setTests((t) => ({ ...t, [id]: { running: true } }))
    void window.omi
      .codingAgentTest(id, getPreferences().agentCommands)
      .then((r) => {
        // A needs-auth verdict for Claude Code means the token is gone/expired —
        // reflect it in the sign-in row rather than as a bare test failure.
        if (r.needsAuth) refreshClaudeAuth()
        setTests((t) => ({
          ...t,
          [id]: { running: false, verdict: r.ok ? 'ok' : 'failed', detail: r.error }
        }))
      })
      .catch((e: Error) =>
        setTests((t) => ({ ...t, [id]: { running: false, verdict: 'failed', detail: e.message } }))
      )
  }

  // One-click Connect: fill + save the known launch command, then run the real
  // handshake. The row flips to "connected" as soon as the command is saved; the
  // Test line then confirms the agent actually answered.
  const connect = (id: ExternalAgentId): void => {
    const cmd = EXTERNAL_AGENT_GUIDES[id].suggestedCommand
    const next = { ...(getPreferences().agentCommands ?? {}), [id]: cmd }
    setCommands((c) => ({ ...c, [id]: cmd }))
    setPreferences({ agentCommands: next })
    refresh()
    runTest(id)
  }

  const disconnect = (id: ExternalAgentId): void => {
    const next = { ...(getPreferences().agentCommands ?? {}) }
    delete next[id]
    setCommands((c) => {
      const n = { ...c }
      delete n[id]
      return n
    })
    setPreferences({ agentCommands: next })
    setTests((t) => ({ ...t, [id]: {} }))
    refresh()
  }

  const copyInstall = (id: ExternalAgentId): void => {
    const cmds = EXTERNAL_AGENT_GUIDES[id].installCommands
    if (cmds.length === 0) return
    void navigator.clipboard
      .writeText(cmds.join('\n'))
      .then(() => {
        setCopied((s) => ({ ...s, [id]: true }))
        setTimeout(() => setCopied((s) => ({ ...s, [id]: false })), 1500)
      })
      .catch(() => {})
  }

  const saveCodexKey = (): void => {
    const key = codexKey.input.trim()
    if (!key) return
    setCodexKey((k) => ({ ...k, saving: true, result: undefined }))
    void window.omi
      .codingAgentSetCodexKey(key)
      .then((r) => {
        setCodexKey({
          hasKey: r.hasKey,
          input: '',
          saving: false,
          result: r.ok
            ? { ok: true, msg: r.warning ?? t('Key saved and verified.', '密钥已保存并验证。') }
            : { ok: false, msg: r.error ?? t('Could not save the key.', '无法保存密钥。') }
        })
      })
      .catch(() =>
        setCodexKey((k) => ({
          ...k,
          saving: false,
          result: { ok: false, msg: t('Could not save the key.', '无法保存密钥。') }
        }))
      )
  }

  const removeCodexKey = (): void => {
    setCodexKey((k) => ({ ...k, saving: true, result: undefined }))
    void window.omi
      .codingAgentSetCodexKey('')
      .then((r) =>
        setCodexKey({
          hasKey: r.hasKey,
          input: '',
          saving: false,
          result: { ok: true, msg: t('Key removed.', '密钥已移除。') }
        })
      )
      .catch(() => setCodexKey((k) => ({ ...k, saving: false })))
  }

  const testLine = (id: CodingAgentId): React.JSX.Element | null => {
    const state = tests[id]
    if (!state?.verdict) return null
    return state.verdict === 'ok' ? (
      <div className="mt-2 text-sm text-emerald-400">
        {t('Connected — the agent answered the handshake.', '已连接 —— 智能体应答了握手。')}
      </div>
    ) : (
      <div className="mt-2 text-sm text-amber-400">
        {state.detail ?? t("Couldn't reach the agent.", '无法连接到智能体。')}
      </div>
    )
  }

  const claudeConnected = claudeAuth.status?.connected ?? false

  const renderExternalAgent = (id: ExternalAgentId): React.JSX.Element => {
    const guide = EXTERNAL_AGENT_GUIDES[id]
    const info = agents.find((a) => a.id === id)
    const displayName = info?.displayName ?? id
    const connected = info?.connected ?? false
    const det = detection[id]
    const installed = det?.installed ?? false
    const busy = tests[id]?.running ?? false

    return (
      <SettingRow
        key={id}
        icon={Terminal}
        title={displayName}
        subtitle={guide.description}
        keywords={`${id} coding agent acp command connect install detect api key`}
        dot={connected ? 'on' : 'off'}
        note={
          det ? (
            installed ? (
              <span className="text-sm text-emerald-400">
                {t(`CLI installed${det.version ? ` · v${det.version}` : ''}`, `CLI 已安装${det.version ? ` · v${det.version}` : ''}`)}
              </span>
            ) : (
              <span className="text-sm text-text-tertiary">{t('CLI not found on PATH', 'PATH 中未找到 CLI')}</span>
            )
          ) : null
        }
        control={
          connected ? (
            <div className="flex items-center gap-2">
              <button
                onClick={() => runTest(id)}
                disabled={busy}
                className="btn-ghost disabled:opacity-40"
              >
                {busy ? t('Testing…', '测试中…') : t('Test', '测试')}
              </button>
              <button onClick={() => disconnect(id)} className="btn-ghost">
                {t('Disconnect', '断开')}
              </button>
            </div>
          ) : (
            <button
              onClick={() => connect(id)}
              disabled={busy}
              className="btn-ghost disabled:opacity-40"
            >
              {busy ? t('Connecting…', '连接中…') : t('Connect', '连接')}
            </button>
          )
        }
      >
        {/* Install guidance when the CLI isn't detected. */}
        {!installed && (
          <div className="mb-3 rounded-lg bg-white/[0.04] p-3 text-sm text-text-tertiary">
            <div className="mb-1 font-medium text-text-secondary">{t(`Install ${displayName}`, `安装 ${displayName}`)}</div>
            {guide.installCommands.map((cmd) => (
              <code key={cmd} className="mb-1 block font-mono text-xs text-text-secondary">
                {cmd}
              </code>
            ))}
            {guide.installNote && <div className="mb-1 text-xs">{guide.installNote}</div>}
            <div className="mt-2 flex items-center gap-4">
              {guide.installCommands.length > 0 && (
                <button onClick={() => copyInstall(id)} className="text-xs underline">
                  {copied[id] ? t('Copied', '已复制') : t('Copy install command', '复制安装命令')}
                </button>
              )}
              <a
                href={guide.docsUrl}
                target="_blank"
                rel="noreferrer"
                className="text-xs underline"
              >
                {t('Setup guide', '安装指南')}
              </a>
            </div>
          </div>
        )}

        {/* Sign-in pointer (we don't automate these external logins). */}
        {!connected && <div className="mb-3 text-sm text-text-tertiary">{guide.authNote}</div>}

        {/* Codex-only: paste-your-OpenAI-key lane (validated, no browser sign-in). */}
        {guide.supportsApiKey && (
          <div className="mb-3 rounded-lg bg-white/[0.04] p-3">
            <div className="mb-1 text-sm font-medium text-text-secondary">{t('OpenAI API key', 'OpenAI API 密钥')}</div>
            <div className="mb-2 text-xs text-text-tertiary">
              {codexKey.hasKey
                ? t('A key is saved — Codex will use it to authenticate.', '已保存密钥 —— Codex 将用它鉴权。')
                : t("Paste your OpenAI API key and we'll validate it — no browser sign-in needed.", '粘贴你的 OpenAI API 密钥，我们会验证 —— 无需浏览器登录。')}
            </div>
            <div className="flex items-center gap-2">
              <input
                type="password"
                value={codexKey.input}
                onChange={(e) => setCodexKey((k) => ({ ...k, input: e.target.value }))}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') {
                    e.preventDefault()
                    saveCodexKey()
                  }
                }}
                placeholder={codexKey.hasKey ? t('•••••••••••• (saved)', '••••••••••••（已保存）') : 'sk-…'}
                className="glass-subtle w-full rounded-lg px-4 py-3 font-mono text-sm text-text-secondary focus:outline-none"
                spellCheck={false}
                autoComplete="off"
              />
              <button
                onClick={saveCodexKey}
                disabled={codexKey.saving || !codexKey.input.trim()}
                className="btn-ghost shrink-0 disabled:opacity-40"
              >
                {codexKey.saving ? t('Saving…', '保存中…') : t('Save', '保存')}
              </button>
              {codexKey.hasKey && (
                <button
                  onClick={removeCodexKey}
                  disabled={codexKey.saving}
                  className="btn-ghost shrink-0 disabled:opacity-40"
                >
                  {t('Remove', '移除')}
                </button>
              )}
            </div>
            {codexKey.result && (
              <div
                className={`mt-2 text-xs ${codexKey.result.ok ? 'text-emerald-400' : 'text-amber-400'}`}
              >
                {codexKey.result.msg}
              </div>
            )}
          </div>
        )}

        {/* Advanced: the raw launch command (original manual path, for power users). */}
        <button
          onClick={() => setAdvancedOpen((s) => ({ ...s, [id]: !s[id] }))}
          className="text-xs text-text-tertiary underline"
        >
          {advancedOpen[id] ? t('Hide advanced', '收起高级') : t('Advanced: custom launch command', '高级：自定义启动命令')}
        </button>
        {advancedOpen[id] && (
          <div className="mt-2 flex items-center gap-2">
            <input
              value={commands[id] ?? ''}
              onChange={(e) => setCommands((c) => ({ ...c, [id]: e.target.value }))}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  e.preventDefault()
                  saveCommand(id)
                }
              }}
              placeholder={t(`Launch command, e.g. ${guide.suggestedCommand}`, `启动命令，例如 ${guide.suggestedCommand}`)}
              className="glass-subtle w-full rounded-lg px-4 py-3 font-mono text-sm text-text-secondary focus:outline-none"
              spellCheck={false}
            />
            <button onClick={() => saveCommand(id)} className="btn-ghost shrink-0">
              {t('Save', '保存')}
            </button>
          </div>
        )}
        {testLine(id)}
      </SettingRow>
    )
  }

  return (
    <div>
      <p className="mb-2 text-sm text-text-tertiary">
        {t(
          'Ask for an agent by name in chat or push-to-talk — “ask Codex to fix the failing test”, “use Claude Code to add a readme” — and Omi hands the task over, streaming the agent’s progress into the conversation. If the agent you named is down, Omi falls back to the next connected one.',
          '在聊天或长按说话时点名智能体 —— 「让 Codex 修复失败的测试」「用 Claude Code 加个 readme」——小蜗会把任务移交过去，并把智能体的进度流式呈现到对话里。点名的智能体不可用时，小蜗会回退到下一个已连接的。'
        )}
      </p>

      <SettingRow
        icon={Bot}
        title="Claude Code"
        subtitle={
          claudeConnected
            ? t('Built in — signed in with your Claude account.', '内置 —— 已用你的 Claude 账户登录。')
            : t('Built in — no install needed. Sign in with your Claude account to use it.', '内置 —— 无需安装。用你的 Claude 账户登录即可使用。')
        }
        keywords="claude code anthropic coding agent builtin sign in login authenticate"
        dot={claudeConnected ? 'on' : 'off'}
        control={
          claudeConnected ? (
            <div className="flex items-center gap-2">
              <button
                onClick={() => runTest('acp')}
                disabled={tests.acp?.running}
                className="btn-ghost disabled:opacity-40"
              >
                {tests.acp?.running ? t('Testing…', '测试中…') : t('Test', '测试')}
              </button>
              <button onClick={signOutOfClaude} className="btn-ghost">
                {t('Disconnect', '断开')}
              </button>
            </div>
          ) : (
            <button
              onClick={signInToClaude}
              disabled={claudeAuth.busy || claudeAuth.status === null}
              className="btn-ghost disabled:opacity-40"
            >
              {claudeAuth.busy ? t('Signing in…', '登录中…') : t('Sign in to Claude', '登录 Claude')}
            </button>
          )
        }
      >
        {claudeAuth.busy && (
          <div className="mt-2 text-sm text-text-tertiary">
            {t('Finish signing in in your browser, then come back here.', '在浏览器中完成登录，然后回到这里。')}
          </div>
        )}
        {claudeAuth.error && <div className="mt-2 text-sm text-amber-400">{claudeAuth.error}</div>}
        {claudeConnected && testLine('acp')}
      </SettingRow>

      {(Object.keys(EXTERNAL_AGENT_GUIDES) as ExternalAgentId[]).map((id) =>
        renderExternalAgent(id)
      )}
    </div>
  )
}
