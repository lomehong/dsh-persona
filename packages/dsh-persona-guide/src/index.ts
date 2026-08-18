/**
 * dsh-persona-guide 分身指引插件
 *
 * 提供分身搭建框架文档的 HTTP 接口，供客户端 Tab 读取。
 * 文档目录：D:\Woker\docs\
 */
import type { Context } from '@deepseek-ai/cordis'
import { readFileSync, readdirSync } from 'node:fs'
import { resolve } from 'node:path'

export const name = 'dsh-persona-guide'
export const inject = ['webServer']

export function apply(ctx: Context): void {
  ctx.logger?.info?.('[dsh-persona-guide] 分身指引插件已加载')

  ctx.inject(['webServer'], (wctx: Context) => {
    const web = wctx.get('webServer') as unknown as {
      register: (route: { kind: string; path: string; handler: (req: unknown, res: unknown) => void }) => void
    }

    // GET /dsh-persona-guide/docs - 返回所有文档
    web.register({
      kind: 'exact',
      path: '/dsh-persona-guide/docs',
      handler: (_req: unknown, res: unknown) => {
        try {
          const docsPath = resolve('D:\\Woker\\docs')
          const files = readdirSync(docsPath).filter(f => f.endsWith('.md'))
          const docs: Array<{ name: string; content: string }> = []
          for (const file of files) {
            const content = readFileSync(resolve(docsPath, file), 'utf-8')
            docs.push({ name: file.replace(/\.md$/, ''), content })
          }
          const res2 = res as { writeHead: (code: number, headers: Record<string, string>) => void; end: (data: string) => void }
          res2.writeHead(200, { 'Content-Type': 'application/json' })
          res2.end(JSON.stringify({ ok: true, docs }))
        } catch (error) {
          const res2 = res as { writeHead: (code: number, headers: Record<string, string>) => void; end: (data: string) => void }
          res2.writeHead(500, { 'Content-Type': 'application/json' })
          res2.end(JSON.stringify({ ok: false, error: error instanceof Error ? error.message : String(error) }))
        }
      },
    })

    ctx.logger?.info?.('[dsh-persona-guide] API 路由已注册')
  })
}