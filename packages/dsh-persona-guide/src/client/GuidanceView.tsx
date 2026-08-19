/**
 * 分身指引视图 - 对话区域的第四个 Tab
 *
 * 渲染 ~/.dsh/persona-docs/ 下的 Markdown 文档（固定目录，不随工作区变化）。
 * 使用 react-markdown + remark-gfm 渲染（完整 GFM：表格、嵌套列表、任务列表等），
 * 颜色接入 DSH 前端的 dsw-alias 设计令牌，自动适配明暗主题。
 */
import { useState, useEffect, useCallback } from 'react'
import { createElement, type CSSProperties, type ReactNode } from 'react'
import type { ConvViewProps } from '@deepseek-ai/dsh-client-ui-conversation/client/contract/slots'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'

interface DocInfo {
  name: string
  content: string
}

/* ===== 主题令牌（带回退值，脱离 DSH 主题时也能看） ===== */

const c = {
  text: 'var(--dsw-alias-label-primary, #1f2329)',
  textSecondary: 'var(--dsw-alias-label-secondary, #4e5969)',
  textTertiary: 'var(--dsw-alias-label-tertiary, #86909c)',
  bgBase: 'var(--dsw-alias-bg-base, #ffffff)',
  bgHover: 'var(--dsw-alias-interactive-bg-hover, rgba(31, 35, 41, 0.06))',
  border: 'var(--dsw-alias-separator-primary, #e5e6eb)',
  borderLight: 'var(--dsw-alias-border-l, rgba(31, 35, 41, 0.1))',
  accent: 'var(--dsw-alias-state-business-primary, #3370ff)',
  error: 'var(--dsw-alias-state-error-primary, #f53f3f)',
  codeFont: 'var(--ds-font-family-code, ui-monospace, Consolas, monospace)',
}

/* ===== Markdown 元素样式 ===== */

const mdStyle: Record<string, CSSProperties> = {
  h1: { fontSize: '22px', fontWeight: 700, margin: '28px 0 14px', paddingBottom: '10px', borderBottom: `1px solid ${c.border}`, lineHeight: 1.4, color: c.text },
  h2: { fontSize: '18px', fontWeight: 700, margin: '26px 0 12px', lineHeight: 1.4, color: c.text },
  h3: { fontSize: '15.5px', fontWeight: 600, margin: '20px 0 8px', lineHeight: 1.4, color: c.text },
  h4: { fontSize: '14px', fontWeight: 600, margin: '16px 0 6px', color: c.text },
  p: { margin: '10px 0', lineHeight: 1.85, fontSize: '14px', color: c.text },
  a: { color: c.accent, textDecoration: 'none' },
  ul: { margin: '8px 0', paddingLeft: '22px' },
  ol: { margin: '8px 0', paddingLeft: '26px' },
  li: { margin: '5px 0', lineHeight: 1.8, fontSize: '14px', color: c.text },
  /* 代码块：深色底自成一体的配色，明暗主题下都清晰 */
  pre: {
    background: '#1e1e2e', color: '#cdd6f4', padding: '14px 16px', borderRadius: '10px',
    overflow: 'auto', fontSize: '12.5px', lineHeight: 1.6, fontFamily: c.codeFont, margin: '12px 0',
  },
  codeInline: {
    background: c.bgHover, color: c.text, padding: '1.5px 6px', borderRadius: '4px',
    fontSize: '0.9em', fontFamily: c.codeFont,
  },
  codeInPre: { background: 'transparent', color: 'inherit', padding: 0, borderRadius: 0, fontSize: 'inherit', fontFamily: 'inherit' },
  blockquote: {
    borderLeft: `3px solid ${c.accent}`, background: c.bgHover, padding: '10px 16px',
    margin: '12px 0', borderRadius: '0 8px 8px 0', color: c.textSecondary,
  },
  table: { width: 'max-content', maxWidth: '100%', borderCollapse: 'collapse', margin: '14px 0', fontSize: '13.5px', display: 'block', overflowX: 'auto' },
  th: { padding: '9px 14px', textAlign: 'left', fontWeight: 600, borderBottom: `2px solid ${c.border}`, background: c.bgHover, color: c.text, whiteSpace: 'nowrap' },
  td: { padding: '8px 14px', borderBottom: `1px solid ${c.borderLight}`, color: c.text, verticalAlign: 'top' },
  hr: { border: 'none', borderTop: `1px solid ${c.border}`, margin: '22px 0' },
  img: { maxWidth: '100%', borderRadius: '8px' },
}

/** 用指定标签与内联样式渲染 Markdown 元素（剥离 react-markdown 传入的 node prop） */
function el(tag: string, style?: CSSProperties) {
  return (props: Record<string, unknown>) => {
    const { node: _node, children, ...rest } = props
    return createElement(tag, { ...rest, style }, children as ReactNode)
  }
}

const mdComponents = {
  h1: el('h1', mdStyle.h1),
  h2: el('h2', mdStyle.h2),
  h3: el('h3', mdStyle.h3),
  h4: el('h4', mdStyle.h4),
  p: el('p', mdStyle.p),
  a: el('a', mdStyle.a),
  ul: el('ul', mdStyle.ul),
  ol: el('ol', mdStyle.ol),
  li: el('li', mdStyle.li),
  pre: el('pre', mdStyle.pre),
  /* 行内代码与代码块内 code 分别处理：块内 code（含换行）继承 pre 的配色 */
  code: (props: Record<string, unknown>) => {
    const { node: _node, children, className } = props
    const text = Array.isArray(children) ? children.join('') : String(children ?? '')
    const inPre = text.includes('\n') || typeof className === 'string' && className.includes('language-')
    return createElement('code', { className: className as string | undefined, style: inPre ? mdStyle.codeInPre : mdStyle.codeInline }, children as ReactNode)
  },
  blockquote: el('blockquote', mdStyle.blockquote),
  table: el('table', mdStyle.table),
  th: el('th', mdStyle.th),
  td: el('td', mdStyle.td),
  hr: el('hr', mdStyle.hr),
  img: el('img', mdStyle.img),
}

/* ===== 主组件 ===== */

export function GuidanceView(_props: ConvViewProps): JSX.Element {
  const [docs, setDocs] = useState<DocInfo[]>([])
  const [activeDoc, setActiveDoc] = useState<string>('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    try {
      const res = await fetch('/dsh-persona-guide/docs', { headers: { Accept: 'application/json' } })
      const data = await res.json() as { ok: boolean; docs: DocInfo[]; error?: string }
      if (data.ok && data.docs) {
        setDocs(data.docs)
        if (data.docs.length > 0) {
          setActiveDoc(prev => prev || data.docs[0].name)
        }
      } else {
        setError(data.error || '加载失败')
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { load() }, [load])

  const currentDoc = docs.find(d => d.name === activeDoc)

  const styles: Record<string, CSSProperties> = {
    container: { height: '100%', display: 'flex', flexDirection: 'column', background: c.bgBase },
    tabs: { display: 'flex', gap: '4px', padding: '10px 20px 0', borderBottom: `1px solid ${c.borderLight}`, flexShrink: 0 },
    tab: { padding: '7px 16px', fontSize: '13px', cursor: 'pointer', border: 'none', borderRadius: '8px 8px 0 0', color: c.textTertiary, background: 'transparent' },
    tabActive: { padding: '7px 16px', fontSize: '13px', cursor: 'pointer', border: 'none', borderRadius: '8px 8px 0 0', color: c.text, background: c.bgHover, fontWeight: 600 },
    content: {
      flex: 1, overflow: 'auto', padding: '8px 32px 48px',
      maxWidth: 'var(--dsh-chat-content-width, 860px)', width: '100%', margin: '0 auto',
      boxSizing: 'border-box',
    },
    empty: { padding: '60px 0', textAlign: 'center', color: c.textTertiary, fontSize: '14px', lineHeight: 2 },
    loading: { padding: '60px 0', textAlign: 'center', color: c.textTertiary, fontSize: '14px' },
    error: { padding: '16px 20px', color: c.error, fontSize: '14px', background: c.bgHover, borderRadius: '10px', margin: '24px auto', maxWidth: '560px' },
  }

  if (loading) {
    return <div style={styles.loading}>加载中...</div>
  }

  if (error) {
    return <div style={styles.error}>{error}</div>
  }

  return (
    <div style={styles.container}>
      {docs.length > 1 && (
        <div style={styles.tabs}>
          {docs.map(d => (
            <button
              key={d.name}
              style={d.name === activeDoc ? styles.tabActive : styles.tab}
              onClick={() => setActiveDoc(d.name)}
            >
              {d.name}
            </button>
          ))}
        </div>
      )}
      <div style={styles.content}>
        {docs.length === 0 ? (
          <div style={styles.empty}>
            暂无分身指引文档。<br />
            将 Markdown 文档放入 <code style={{ fontFamily: c.codeFont, fontSize: '12.5px' }}>~/.dsh/persona-docs/</code> 后刷新。
          </div>
        ) : (
          <ReactMarkdown remarkPlugins={[remarkGfm]} components={mdComponents}>
            {currentDoc?.content ?? ''}
          </ReactMarkdown>
        )}
      </div>
    </div>
  )
}
