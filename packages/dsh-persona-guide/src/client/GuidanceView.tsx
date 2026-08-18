/**
 * 分身指引视图 - 对话区域的第四个 Tab
 *
 * 渲染 D:\Woker\docs\ 下的 Markdown 文档。
 * 支持基本的 Markdown 语法：标题、列表、表格、代码块、引用、加粗等。
 */
import { useState, useEffect, useCallback } from 'react'
import type { ConvViewProps } from '@deepseek-ai/dsh-client-ui-conversation/client/contract/slots'

/* ===== 简单的 Markdown 渲染器 ===== */

interface MdNode {
  type: 'heading' | 'paragraph' | 'list' | 'ordered-list' | 'code-block' | 'blockquote' | 'table' | 'hr' | 'empty'
  level?: number
  children: (string | MdInlineNode)[]
  items?: string[][]
  lang?: string
  headers?: string[]
  rows?: string[][]
}

type MdInlineNode = 
  | { t: 'text'; v: string }
  | { t: 'bold'; v: string }
  | { t: 'code'; v: string }
  | { t: 'link'; v: string; h: string }
  | { t: 'br' }

function parseInline(text: string): MdInlineNode[] {
  const nodes: MdInlineNode[] = []
  let i = 0
  while (i < text.length) {
    // 加粗 **text**
    if (text.startsWith('**', i)) {
      const end = text.indexOf('**', i + 2)
      if (end !== -1) {
        nodes.push({ t: 'bold', v: text.slice(i + 2, end) })
        i = end + 2
        continue
      }
    }
    // 行内代码 `code`
    if (text[i] === '`') {
      const end = text.indexOf('`', i + 1)
      if (end !== -1) {
        nodes.push({ t: 'code', v: text.slice(i + 1, end) })
        i = end + 1
        continue
      }
    }
    // 链接 [text](url)
    if (text[i] === '[') {
      const close = text.indexOf(']', i)
      if (close !== -1 && text[close + 1] === '(') {
        const paren = text.indexOf(')', close + 2)
        if (paren !== -1) {
          nodes.push({ t: 'link', v: text.slice(i + 1, close), h: text.slice(close + 2, paren) })
          i = paren + 1
          continue
        }
      }
    }
    // 普通文本
    if (text[i] === '\n') {
      nodes.push({ t: 'br' })
      i++
    } else {
      const start = i
      while (i < text.length && text[i] !== '\n' && text[i] !== '`' && text[i] !== '[' && !(text[i] === '*' && text[i + 1] === '*')) {
        i++
      }
      if (i > start) nodes.push({ t: 'text', v: text.slice(start, i) })
    }
  }
  return nodes
}

function parseMarkdown(md: string): MdNode[] {
  const lines = md.split('\n')
  const nodes: MdNode[] = []
  let i = 0

  while (i < lines.length) {
    const line = lines[i]

    // 空行
    if (line.trim() === '') {
      if (nodes.length > 0 && nodes[nodes.length - 1].type !== 'empty') {
        nodes.push({ type: 'empty', children: [] })
      }
      i++
      continue
    }

    // 分隔线 ---
    if (/^-{3,}$/.test(line.trim())) {
      nodes.push({ type: 'hr', children: [] })
      i++
      continue
    }

    // 标题
    const headingMatch = line.match(/^(#{1,6})\s+(.+)$/)
    if (headingMatch) {
      nodes.push({
        type: 'heading',
        level: headingMatch[1].length,
        children: parseInline(headingMatch[2]),
      })
      i++
      continue
    }

    // 引用块
    if (line.startsWith('> ')) {
      const quoteLines: string[] = []
      while (i < lines.length && lines[i].startsWith('> ')) {
        quoteLines.push(lines[i].slice(2))
        i++
      }
      nodes.push({ type: 'blockquote', children: parseInline(quoteLines.join('\n')) })
      continue
    }

    // 无序列表
    if (line.match(/^[-*+]\s/)) {
      const items: string[][] = []
      while (i < lines.length && lines[i].match(/^[-*+]\s/)) {
        items.push(parseInline(lines[i].replace(/^[-*+]\s/, '')))
        i++
      }
      // 处理缩进的子项
      nodes.push({ type: 'list', children: [], items: items.map(item => item.map(n => { if (typeof n === 'string') return n; if (n.t === 'text') return n.v; return '' })) })
      // 用字符串表示
      const itemStrings = items.map(item => item.map(n => n.t === 'text' ? n.v : n.t === 'bold' ? n.v : n.t === 'code' ? n.v : n.t === 'link' ? n.v : '').join(''))
      nodes.push({ type: 'list', children: [], items: itemStrings })
      continue
    }

    // 有序列表
    if (line.match(/^\d+\.\s/)) {
      const items: string[][] = []
      while (i < lines.length && lines[i].match(/^\d+\.\s/)) {
        items.push(parseInline(lines[i].replace(/^\d+\.\s/, '')))
        i++
      }
      const itemStrings = items.map(item => item.map(n => n.t === 'text' ? n.v : n.t === 'bold' ? n.v : n.t === 'code' ? n.v : n.t === 'link' ? n.v : '').join(''))
      nodes.push({ type: 'ordered-list', children: [], items: itemStrings })
      continue
    }

    // 代码块
    if (line.startsWith('```')) {
      const lang = line.slice(3).trim()
      const codeLines: string[] = []
      i++
      while (i < lines.length && !lines[i].startsWith('```')) {
        codeLines.push(lines[i])
        i++
      }
      i++ // skip closing ```
      nodes.push({ type: 'code-block', children: [], lang: lang || undefined, items: [codeLines.join('\n')] })
      continue
    }

    // 表格
    if (line.includes('|') && lines[i + 1] && lines[i + 1].match(/^[\s|:-]+$/)) {
      const headers = line.split('|').map(s => s.trim()).filter(Boolean)
      const rows: string[][] = []
      i += 2 // skip header and separator
      while (i < lines.length && lines[i].includes('|')) {
        const cells = lines[i].split('|').map(s => s.trim()).filter(Boolean)
        rows.push(cells)
        i++
      }
      nodes.push({ type: 'table', children: [], headers, rows })
      continue
    }

    // 普通段落
    const paraLines: string[] = [line]
    i++
    while (i < lines.length && lines[i].trim() !== '' && !lines[i].startsWith('#') && !lines[i].startsWith('```') && !lines[i].startsWith('> ') && !lines[i].match(/^[-*+]\s/) && !lines[i].match(/^\d+\.\s/) && !lines[i].includes('|') && !/^-{3,}$/.test(lines[i].trim())) {
      paraLines.push(lines[i])
      i++
    }
    nodes.push({ type: 'paragraph', children: parseInline(paraLines.join('\n')) })
  }

  return nodes
}

/* ===== React 渲染组件 ===== */

function renderInline(nodes: MdInlineNode[], keyPrefix: string): JSX.Element[] {
  return nodes.map((n, i) => {
    const k = keyPrefix + '-' + i
    switch (n.t) {
      case 'text': return <span key={k}>{n.v}</span>
      case 'bold': return <strong key={k}>{n.v}</strong>
      case 'code': return <code key={k} style={{ background: '#f0f0f0', padding: '2px 6px', borderRadius: '3px', fontSize: '0.9em', fontFamily: 'monospace' }}>{n.v}</code>
      case 'link': return <a key={k} href={n.h} target="_blank" rel="noopener noreferrer" style={{ color: '#4a6cf7' }}>{n.v}</a>
      case 'br': return <br key={k} />
    }
  })
}

function renderMdToReact(nodes: MdNode[], keyPrefix: string): JSX.Element[] {
  let idx = 0
  const result: JSX.Element[] = []

  for (const node of nodes) {
    if (node.type === 'empty') continue
    const k = keyPrefix + '-' + (idx++)

    switch (node.type) {
      case 'heading': {
        const content = renderInline(node.children, k + '-i')
        switch (node.level) {
          case 1: result.push(<h1 key={k} style={{ fontSize: '22px', margin: '20px 0 10px 0', color: '#1a1a2e', borderBottom: '2px solid #eee', paddingBottom: '6px' }}>{content}</h1>); break
          case 2: result.push(<h2 key={k} style={{ fontSize: '18px', margin: '18px 0 8px 0', color: '#2c3e50' }}>{content}</h2>); break
          case 3: result.push(<h3 key={k} style={{ fontSize: '16px', margin: '14px 0 6px 0', color: '#34495e' }}>{content}</h3>); break
          default: result.push(<h4 key={k} style={{ fontSize: '14px', margin: '10px 0 4px 0', color: '#555', fontWeight: 600 }}>{content}</h4>)
        }
        break
      }
      case 'paragraph': {
        const content = renderInline(node.children, k + '-i')
        result.push(<p key={k} style={{ margin: '8px 0', lineHeight: '1.7', fontSize: '14px', color: '#333' }}>{content}</p>)
        break
      }
      case 'list': {
        const items = (node.items || []).map((item, ii) => <li key={k + '-li-' + ii} style={{ margin: '4px 0', lineHeight: '1.6', fontSize: '14px' }}>{item}</li>)
        result.push(<ul key={k} style={{ paddingLeft: '24px', margin: '8px 0' }}>{items}</ul>)
        break
      }
      case 'ordered-list': {
        const items = (node.items || []).map((item, ii) => <li key={k + '-li-' + ii} style={{ margin: '4px 0', lineHeight: '1.6', fontSize: '14px' }}>{item}</li>)
        result.push(<ol key={k} style={{ paddingLeft: '24px', margin: '8px 0' }}>{items}</ol>)
        break
      }
      case 'code-block': {
        const code = (node.items && node.items[0]) || ''
        result.push(
          <pre key={k} style={{ background: '#1e1e2e', color: '#cdd6f4', padding: '14px', borderRadius: '8px', overflow: 'auto', fontSize: '13px', lineHeight: '1.5', fontFamily: '"Cascadia Code","Fira Code",monospace', margin: '10px 0' }}>
            <code>{code}</code>
          </pre>
        )
        break
      }
      case 'blockquote': {
        const content = node.children.length > 0 ? renderInline(node.children, k + '-i') : null
        result.push(
          <blockquote key={k} style={{ borderLeft: '4px solid #4a6cf7', background: '#f0f4ff', padding: '10px 16px', margin: '10px 0', borderRadius: '0 6px 6px 0', fontSize: '14px', color: '#444' }}>
            {content}
          </blockquote>
        )
        break
      }
      case 'table': {
        const headers = (node.headers || []).map((h, ii) => <th key={k + '-th-' + ii} style={{ padding: '8px 12px', textAlign: 'left', borderBottom: '2px solid #ddd', fontWeight: 600, fontSize: '13px', background: '#fafafa', color: '#555' }}>{h}</th>)
        const rows = (node.rows || []).map((row, ri) => (
          <tr key={k + '-tr-' + ri}>
            {row.map((cell, ci) => <td key={k + '-td-' + ri + '-' + ci} style={{ padding: '8px 12px', borderBottom: '1px solid #eee', fontSize: '13px' }}>{cell}</td>)}
          </tr>
        ))
        result.push(
          <table key={k} style={{ width: '100%', borderCollapse: 'collapse', margin: '10px 0', background: '#fff', borderRadius: '6px', boxShadow: '0 1px 3px rgba(0,0,0,0.08)' }}>
            <thead><tr>{headers}</tr></thead>
            <tbody>{rows}</tbody>
          </table>
        )
        break
      }
      case 'hr': {
        result.push(<hr key={k} style={{ border: 'none', borderTop: '1px solid #ddd', margin: '16px 0' }} />)
        break
      }
    }
  }

  return result
}

/* ===== 文档选择器 ===== */

interface DocInfo {
  name: string
  content: string
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
        if (data.docs.length > 0 && !activeDoc) {
          setActiveDoc(data.docs[0].name)
        }
      } else {
        setError(data.error || '加载失败')
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [activeDoc])

  useEffect(() => { load() }, [load])

  const currentDoc = docs.find(d => d.name === activeDoc)
  const mdNodes = currentDoc ? parseMarkdown(currentDoc.content) : []
  const rendered = currentDoc ? renderMdToReact(mdNodes, 'md') : []

  const styles: Record<string, React.CSSProperties> = {
    container: { height: '100%', display: 'flex', flexDirection: 'column' },
    tabs: { display: 'flex', gap: '2px', padding: '8px 12px 0', background: '#f5f5f5', borderBottom: '1px solid #ddd', flexShrink: 0 },
    tab: { padding: '6px 14px', fontSize: '13px', cursor: 'pointer', border: '1px solid transparent', borderBottom: 'none', borderRadius: '6px 6px 0 0', color: '#666', background: 'transparent' },
    tabActive: { padding: '6px 14px', fontSize: '13px', cursor: 'pointer', border: '1px solid #ddd', borderBottom: '1px solid #fff', borderRadius: '6px 6px 0 0', color: '#1a1a2e', background: '#fff', fontWeight: 600, marginBottom: '-1px' },
    content: { flex: 1, overflow: 'auto', padding: '16px 24px' },
    loading: { padding: '40px', textAlign: 'center', color: '#999', fontSize: '14px' },
    error: { padding: '20px', color: '#e74c3c', fontSize: '14px', background: '#fdf0ef', borderRadius: '8px', margin: '16px' },
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
        {rendered}
      </div>
    </div>
  )
}