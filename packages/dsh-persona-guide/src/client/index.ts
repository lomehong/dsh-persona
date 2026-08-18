/**
 * dsh-persona-guide 客户端插件入口
 *
 * 在对话区域注册「分身指引」Tab，位于记忆之后。
 */
import type { ClientContext } from '@deepseek-ai/dsh-client-runtime/client'
import type {} from '@deepseek-ai/dsh-client-ui-conversation/client'
import type {} from '@deepseek-ai/dsh-client-ui-slots'
import { GuidanceView } from './GuidanceView.tsx'

export const inject = ['slots']

export function apply(ctx: ClientContext): void {
  ctx.slots.inject('conversation.view', () => ctx.slots.register({
    name: 'conversation.view',
    id: 'persona-guide',
    order: 30,
    label: () => '分身指引',
  }, GuidanceView))
}