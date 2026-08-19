/**
 * dsh-persona-guide 分身指引插件
 *
 * 提供分身搭建框架文档的 HTTP 接口，供客户端 Tab 读取。
 * 文档目录固定为 ~/.dsh/persona-docs（机器级路径，不随工作区切换变化），
 * 可通过 config.docsDir 覆盖；目录不存在时返回空列表而非报错。
 */
import type { Context } from '@deepseek-ai/cordis'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const name = 'dsh-persona-guide'
export const inject = ['webServer']

interface GuideConfig {
  docsDir?: string
}

export function apply(ctx: Context, config: GuideConfig = {}): void {
  ctx.logger?.info?.('[dsh-persona-guide] 分身指引插件已加载')

  const docsPath = config.docsDir ?? join(homedir(), '.dsh', 'persona-docs')

  ctx.inject(['webServer'], (wctx: Context) => {
    const web = wctx.get('webServer') as unknown as {
      register: (route: { kind: string; path: string; handler: (req: unknown, res: unknown) => void }) => void
    }

    // GET /dsh-persona-guide/docs - 返回所有文档
    web.register({
      kind: 'exact',
      path: '/dsh-persona-guide/docs',
      handler: (_req: unknown, res: unknown) => {
        const res2 = res as { writeHead: (code: number, headers: Record<string, string>) => void; end: (data: string) => void }
        try {
          const docs: Array<{ name: string; content: string }> = []
          if (existsSync(docsPath)) {
            const files = readdirSync(docsPath).filter(f => f.endsWith('.md'))
            for (const file of files) {
              const content = readFileSync(join(docsPath, file), 'utf-8')
              docs.push({ name: file.replace(/\.md$/, ''), content })
            }
          }
          res2.writeHead(200, { 'Content-Type': 'application/json' })
          res2.end(JSON.stringify({ ok: true, docs }))
        } catch (error) {
          res2.writeHead(500, { 'Content-Type': 'application/json' })
          res2.end(JSON.stringify({ ok: false, error: error instanceof Error ? error.message : String(error) }))
        }
      },
    })

    ctx.logger?.info?.(`[dsh-persona-guide] API 路由已注册，文档目录: ${docsPath}`)
  })
}
