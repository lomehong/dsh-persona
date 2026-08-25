// DSH 数字分身安装向导 — 前端逻辑
//
// 设计要点：
//   - 不引框架，4 屏单页 + 单 module 状态对象 state；
//   - state 跨屏持久，所有字段就是后端 InstallRequest 的 1:1 镜像；
//   - 子进程事件通过 window.__TAURI__.event.listen('install-event', ...)
//     接住，按 kind 字段路由到 log / phase / exit / error。

const state = {
  step: 0,            // 当前屏 0..3
  prereq: null,       // 后端 check_prereq 返回值
  installRunning: false,
  installExit: null,  // { code, success }
  request: {
    packagesDir: '',
    botId: '',
    secret: '',
    owner: '',
    ownerTitle: '',
    ownerStance: '',
    ownerScope: '',
    ownerStyle: '',
    ownerAddress: '',
    twinName: '',
    twinAliases: '',
    launchAfter: false,
  },
};

const $  = (id) => document.getElementById(id);
const $$ = (sel) => document.querySelectorAll(sel);

function getTauri() {
  return (window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.event) || null;
}

function showScreen(idx) {
  state.step = idx;
  $$('.screen').forEach((el) => {
    el.hidden = Number(el.dataset.screen) !== idx;
  });
  $$('.steps li').forEach((li) => {
    const s = Number(li.dataset.step);
    li.classList.toggle('active', s === idx);
    li.classList.toggle('done', s < idx);
  });
  $('btn-back').disabled = idx === 0;
  $('btn-next').hidden = idx === 3;          // 屏 4 由「开始安装」按钮驱动
  $('btn-cancel').hidden = !(idx === 3 && state.installRunning);
  $('btn-next').textContent = idx === 3 ? '开始安装' : '下一步';
  $('btn-next').disabled = idx === 3 && state.installRunning;
}

function bindNav() {
  $('btn-back').addEventListener('click', () => {
    if (state.step === 0) return;
    showScreen(state.step - 1);
  });

  $('btn-next').addEventListener('click', async () => {
    if (state.step < 3) {
      // 屏 1（环境检查）→ 屏 2 之前先拉一次 prereq
      if (state.step === 1 && !state.prereq) {
        await runPrereq();
      }
      showScreen(state.step + 1);
      return;
    }
    // 屏 4：开始安装
    await startInstall();
  });

  $('btn-cancel').addEventListener('click', async () => {
    if (!state.installRunning) return;
    const t = getTauri();
    if (!t) return;
    try { await t.invoke('cancel_setup'); } catch (e) { appendLog('stderr', '取消失败: ' + e); }
  });
}

// ── 屏 2：环境检查 ──

async function runPrereq() {
  const t = getTauri();
  if (!t) {
    setPrereq('node', 'fail', '运行环境异常（Tauri 不可用）');
    setPrereq('git', 'pending', '跳过（开发模式）');
    setPrereq('net', 'pending', '跳过');
    setPrereq('script', 'pending', '跳过');
    return;
  }
  try {
    const report = await t.invoke('check_prereq');
    state.prereq = report;
    setPrereq('node', report.node ? 'ok' : 'fail', report.node || '未检测到（将自动安装便携版）');
    setPrereq('git', report.git ? 'ok' : 'fail', report.git || '未检测到');
    setPrereq('net', report.networkOk ? 'ok' : 'fail', report.networkOk ? '可达 codeload.github.com' : 'GitHub 不可达，请检查代理/防火墙');
    setPrereq('script', report.setupScriptFound ? 'ok' : 'fail', report.setupScriptFound ? report.repoRoot : '未找到 scripts/setup.ps1');
    $('prereq-hint').textContent = report.setupScriptFound
      ? ''
      : '提示：请从 dsh-persona 仓库根目录运行本安装器（scripts/setup.{ps1,sh} 必须存在）。';
  } catch (e) {
    setPrereq('node', 'fail', String(e));
    setPrereq('git', 'fail', '检测失败');
    setPrereq('net', 'fail', '检测失败');
    setPrereq('script', 'fail', '检测失败');
  }
}

function setPrereq(key, kind, value) {
  const dot  = $('dot-' + key);
  const val  = $('val-' + key);
  if (!dot || !val) return;
  dot.classList.remove('ok', 'fail', 'pending');
  dot.classList.add(kind);
  val.textContent = value;
  if (kind === 'fail') val.classList.add('fail'); else val.classList.remove('fail');
}

// ── 屏 3：分身信息 ──

function bindPersona() {
  const fields = [
    ['packagesDir', 'packagesDir'],
    ['owner',       'owner'],
    ['ownerTitle',  'ownerTitle'],
    ['ownerStance', 'ownerStance'],
    ['ownerScope',  'ownerScope'],
    ['ownerStyle',  'ownerStyle'],
    ['ownerAddress','ownerAddress'],
    ['twinName',    'twinName'],
    ['twinAliases', 'twinAliases'],
    ['botId',       'botId'],
    ['secret',      'secret'],
  ];
  fields.forEach(([dom, key]) => {
    const el = $(dom);
    if (!el) return;
    el.value = state.request[key] || '';
    el.addEventListener('input', () => {
      state.request[key] = el.value;
    });
  });
}

// ── 屏 4：安装 ──

function appendLog(stream, text) {
  const log = $('log');
  if (!log) return;
  const div = document.createElement('div');
  if (stream === 'stderr') div.className = 'err';
  else if (text.startsWith('===') || text.includes('===')) div.className = 'step';
  else if (text.includes('✓') || text.includes('OK')) div.className = 'ok';
  div.textContent = text;
  log.appendChild(div);
  // 自动滚到底
  log.scrollTop = log.scrollHeight;
}

function setPhase(idx) {
  $$('.phase').forEach((p) => {
    const i = Number(p.dataset.phase);
    p.classList.toggle('active', i === idx);
    p.classList.toggle('done',   i < idx);
  });
}

async function startInstall() {
  if (state.installRunning) return;
  state.installRunning = true;
  showScreen(3); // 确保显示安装屏

  // 抓取最后一份表单
  const r = state.request;
  const launchAfterEl = $('launchAfter');
  r.launchAfter = !!(launchAfterEl && launchAfterEl.checked);

  const t = getTauri();
  if (!t) {
    appendLog('stderr', 'Tauri 不可用，无法启动子进程');
    state.installRunning = false;
    showScreen(3);
    return;
  }

  $('exit-status').textContent = '';
  $('install-lead').textContent = '正在安装…';
  $('log').textContent = '';
  setPhase(0);

  try {
    await t.invoke('run_setup', { request: r });
    // 流式输出已经在 listen 回调里更新到 UI；这里再 wait 收尾
    const code = await t.invoke('wait_setup');
    state.installExit = { code, success: code === 0 };
    $('exit-status').textContent = state.installExit.success
      ? `安装完成（退出码 ${code}）。` : `安装失败（退出码 ${code}），请查看上方日志。`;
    $('install-lead').textContent = state.installExit.success ? '安装完成' : '安装失败';
    setPhase(9);

    // 成功后展示「立即启动」勾选 + 启动按钮
    const final = $('final-actions');
    final.hidden = !state.installExit.success;
    if (state.installExit.success) {
      // 把 next 按钮改成「启动数字分身」
      $('btn-next').hidden = false;
      $('btn-next').textContent = '启动数字分身';
      $('btn-next').disabled = false;
      state.installRunning = false;
      $('btn-cancel').hidden = true;
    } else {
      $('btn-next').textContent = '重试';
      $('btn-next').disabled = false;
      state.installRunning = false;
    }
  } catch (e) {
    appendLog('stderr', '启动失败: ' + e);
    $('exit-status').textContent = '启动失败：' + e;
    state.installRunning = false;
    showScreen(3);
  }
}

function bindEvents() {
  const t = getTauri();
  if (!t) return;
  t.listen('install-event', (ev) => {
    const p = ev.payload || {};
    if (p.kind === 'log') {
      appendLog(p.stream, p.line);
    } else if (p.kind === 'phase') {
      setPhase(p.index);
      appendLog('stdout', `=== ${p.name} ===`);
    } else if (p.kind === 'exit') {
      // wait_setup 已 emit，由前端处理最终态
    } else if (p.kind === 'error') {
      appendLog('stderr', p.message);
    }
  });
}

// ── 启动入口 ──

function boot() {
  bindNav();
  bindPersona();
  bindEvents();
  showScreen(0);
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', boot);
} else {
  boot();
}