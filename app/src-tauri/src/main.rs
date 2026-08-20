// DSH 数字分身桌面应用：包装便携版 Node 运行时 + dsh web 服务。
// 方案 C：原生窗口 + 关闭最小化到托盘 + 退出才真正结束服务。
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::io::Write;
use std::net::TcpStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::Duration;

use tauri::{
    menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem},
    tray::TrayIconBuilder,
    Emitter, Manager,
};

/// dsh web 服务端口（与启动脚本一致）
const PORT: u16 = 3080;
/// 健康检查最长等待（首次启动要装运行时、连企微，给足时间）
const BOOT_TIMEOUT_SECS: u64 = 120;
/// 服务异常退出后的自动重启上限（一次会话内）
const MAX_AUTO_RESTARTS: u32 = 3;

struct DshState {
    child: Mutex<Option<Child>>,
    restarts: Mutex<u32>,
    launch: Mutex<Option<Launch>>,
}

/// 启动状态：供加载页轮询（事件推送可能早于页面监听器挂载而丢失，轮询更可靠）
#[derive(Default)]
struct StatusState(Mutex<StartupStatus>);

#[derive(Default, Clone, serde::Serialize)]
struct StartupStatus {
    text: String,
    error: bool,
    ready: bool,
}

#[tauri::command]
fn get_status(state: tauri::State<'_, StatusState>) -> StartupStatus {
    state.0.lock().unwrap().clone()
}

fn main() {
    tauri::Builder::default()
        // 二次启动：聚焦已有窗口（须最先注册）
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.show();
                let _ = w.set_focus();
            }
        }))
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .manage(DshState {
            child: Mutex::new(None),
            restarts: Mutex::new(0),
            launch: Mutex::new(None),
        })
        .manage(StatusState::default())
        .invoke_handler(tauri::generate_handler![get_status])
        .setup(|app| {
            build_tray(app.handle())?;
            // 启动序列在后台线程执行，窗口先显示加载页
            let handle = app.handle().clone();
            std::thread::spawn(move || {
                if let Err(err) = startup_sequence(&handle) {
                    update_status(&handle, &err, true, false);
                }
            });
            // 服务守护：异常退出时自动重启
            let watcher = app.handle().clone();
            std::thread::spawn(move || watch_child(&watcher));
            Ok(())
        })
        .on_window_event(|window, event| {
            // 关闭按钮 = 最小化到托盘；服务继续运行（企微/御驿不中断）
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .build(tauri::generate_context!())
        .expect("初始化数字分身失败")
        .run(|app, event| {
            if let tauri::RunEvent::Exit = event {
                // 真正退出：杀掉整个 dsh 进程树，不留孤儿 node
                let state: tauri::State<DshState> = app.state();
                let child = state.child.lock().unwrap().take();
                if let Some(child) = child {
                    kill_tree(child.id() as u32);
                }
            }
        });
}

/* ───────────────────── 运行时路径 ───────────────────── */

/// 便携版运行时根目录（与 setup.ps1 一致）：
/// Windows: %LOCALAPPDATA%\dsh-persona；macOS: ~/Library/Application Support/dsh-persona（第二期）
#[cfg(windows)]
fn runtime_root() -> PathBuf {
    let local = std::env::var("LOCALAPPDATA").unwrap_or_default();
    PathBuf::from(local).join("dsh-persona")
}

#[cfg(not(windows))]
fn runtime_root() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    PathBuf::from(home).join("Library/Application Support/dsh-persona")
}

fn node_exe() -> PathBuf {
    let p = runtime_root().join("node").join(if cfg!(windows) { "node.exe" } else { "bin/node" });
    p
}

fn dsh_bin_js() -> PathBuf {
    // Windows 便携版 npm -g 装到 node\node_modules；macOS 装到 node/lib/node_modules
    let mut p = runtime_root().join("node");
    if !cfg!(windows) {
        p = p.join("lib");
    }
    p.join("node_modules")
        .join("@deepseek-ai")
        .join("dsh")
        .join("lib")
        .join("bin.js")
}

fn log_file() -> PathBuf {
    runtime_root().join("dsh-web.log")
}

/// dsh web 的启动方式：便携版运行时（node + bin.js）或系统 node + 全局 dsh 命令
#[derive(Clone, Copy)]
enum Launch {
    Portable,
    System,
}

/* ───────────────────── 运行时自举 ───────────────────── */

/// 检查命令是否可用（PATH 上能找到）
#[cfg(windows)]
fn command_exists(name: &str) -> bool {
    let mut c = Command::new("where.exe");
    c.arg(name);
    no_window(&mut c)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// 只检测、不安装：node 与 dsh 都就绪才返回启动方式，否则提示先安装。
#[cfg(windows)]
fn bootstrap_runtime(_app: &tauri::AppHandle) -> Result<Launch, String> {
    let node_path = node_exe();
    let bin_path = dsh_bin_js();
    let portable = node_path.exists() && bin_path.exists();
    // 诊断日志：记录检测到的路径与结果，便于排查环境差异
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(log_file()) {
        let _ = writeln!(
            f,
            "[检测] LOCALAPPDATA={:?} node={:?} exists={} bin={:?} exists={} portable={}",
            std::env::var("LOCALAPPDATA").unwrap_or_default(),
            node_path,
            node_path.exists(),
            bin_path,
            bin_path.exists(),
            portable
        );
    }
    if portable {
        return Ok(Launch::Portable);
    }
    let has_node = portable || command_exists("node");
    if !has_node {
        return Err("未检测到 Node.js。\n请先安装 Node.js（https://nodejs.org/），或运行本仓库的 scripts\\setup.ps1 一键安装。".into());
    }
    let has_dsh = command_exists("dsh");
    if !has_dsh {
        return Err("未检测到 DSH。\n请先执行 npm install -g @deepseek-ai/dsh，或运行本仓库的 scripts\\setup.ps1 一键安装。".into());
    }
    Ok(Launch::System)
}

#[cfg(not(windows))]
fn bootstrap_runtime(_app: &tauri::AppHandle) -> Result<Launch, String> {
    Err("macOS 请先运行 scripts/setup.sh 完成安装（第二期交付）".into())
}

/* ───────────────────── 进程管理 ───────────────────── */

/// Windows 下隐藏子进程的控制台窗口
#[cfg(windows)]
fn no_window(cmd: &mut Command) -> &mut Command {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    cmd.creation_flags(CREATE_NO_WINDOW)
}

#[cfg(not(windows))]
fn no_window(cmd: &mut Command) -> &mut Command {
    cmd
}

fn spawn_dsh(launch: Launch) -> Result<Child, String> {
    let mut log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_file())
        .map_err(|e| format!("无法写入日志文件: {e}"))?;
    let log_err = log.try_clone().map_err(|e| format!("{e}"))?;
    let _ = writeln!(log, "\n===== dsh web 由桌面应用启动 {} =====", chrono_now());

    let mut cmd = match launch {
        Launch::Portable => {
            let node = node_exe();
            let bin = dsh_bin_js();
            if !node.exists() || !bin.exists() {
                return Err("便携运行时就绪检查失败，请重新打开本程序。".into());
            }
            let node_dir = node.parent().map(|p| p.to_path_buf()).unwrap_or_default();
            let sys = std::env::var("PATH").unwrap_or_default();
            let sep = if cfg!(windows) { ";" } else { ":" };
            let path_var = format!("{}{}{}", node_dir.display(), sep, sys);
            let mut c = Command::new(&node);
            c.arg(&bin)
                .arg("web")
                .env("PATH", &path_var)
                .current_dir(node_dir);
            c
        }
        Launch::System => {
            // 系统 node + 全局 dsh 命令：经 cmd 调用以解析 PATH 上的 dsh.cmd
            let mut c = Command::new("cmd.exe");
            c.args(["/C", "dsh", "web"]);
            c
        }
    };
    cmd.stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err));
    // macOS/Linux：独立进程组，整组终止不波及父进程（App）
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }
    no_window(&mut cmd).spawn().map_err(|e| format!("启动 dsh web 失败: {e}"))
}

/// 杀掉整个进程树（dsh 会派生工作线程/子进程，必须整树清理）
fn kill_tree(pid: u32) {
    #[cfg(windows)]
    {
        let mut cmd = Command::new("taskkill");
        cmd.args(["/PID", &pid.to_string(), "/T", "/F"]);
        let _ = no_window(&mut cmd).status();
    }
    #[cfg(unix)]
    {
        // spawn 时启用了独立进程组（pgid == pid），负号表示整组信号
        let _ = Command::new("kill").args(["-TERM", &format!("-{pid}")]).status();
        std::thread::sleep(Duration::from_millis(1500));
        let _ = Command::new("kill").args(["-KILL", &format!("-{pid}")]).status();
    }
}

fn port_ready() -> bool {
    TcpStream::connect(("127.0.0.1", PORT)).is_ok()
}

fn wait_port_ready(timeout: Duration) -> bool {
    let start = std::time::Instant::now();
    while start.elapsed() < timeout {
        if port_ready() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    false
}

fn chrono_now() -> String {
    // 无 chrono 依赖：用系统时间戳即可诊断用
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("unix={secs}")
}

/* ───────────────────── 启动序列 ───────────────────── */

fn update_status(app: &tauri::AppHandle, text: &str, error: bool, ready: bool) {
    if let Some(s) = app.try_state::<StatusState>() {
        *s.0.lock().unwrap() = StartupStatus {
            text: text.to_string(),
            error,
            ready,
        };
    }
    let _ = app.emit(
        "startup-status",
        serde_json::json!({ "text": text, "error": error, "ready": ready }),
    );
}

fn set_status(app: &tauri::AppHandle, text: &str, error: bool) {
    update_status(app, text, error, false);
}

fn startup_sequence(app: &tauri::AppHandle) -> Result<(), String> {
    let state: tauri::State<DshState> = app.state();
    if port_ready() {
        // 已有实例在运行（例如开机自启后再次双击）：直接接管窗口
        set_status(app, "检测到运行中的服务，正在连接…", false);
        navigate_to_ui(app);
        return Ok(());
    }
    set_status(app, "检查运行环境（未安装 DSH 时会自动安装）…", false);
    let launch = bootstrap_runtime(app)?;
    *state.launch.lock().unwrap() = Some(launch);
    set_status(app, "正在启动数字分身服务…", false);
    let child = spawn_dsh(launch)?;
    *state.child.lock().unwrap() = Some(child);
    set_status(app, "等待服务就绪（首次启动约需 10~30 秒）…", false);
    if !wait_port_ready(Duration::from_secs(BOOT_TIMEOUT_SECS)) {
        let msg = format!(
            "服务在 {} 秒内未就绪。请查看日志: {}",
            BOOT_TIMEOUT_SECS,
            log_file().display()
        );
        set_status(app, &msg, true);
        return Err(msg);
    }
    navigate_to_ui(app);
    Ok(())
}

/// 读取已记录的启动方式；无记录时重新探测（用于自动重启/手动重启）
fn resolve_launch(app: &tauri::AppHandle) -> Result<Launch, String> {
    let state: tauri::State<DshState> = app.state();
    if let Some(l) = *state.launch.lock().unwrap() {
        return Ok(l);
    }
    let launch = bootstrap_runtime(app)?;
    *state.launch.lock().unwrap() = Some(launch);
    Ok(launch)
}

/// 把主窗口从加载页导航到 dsh web 界面
fn navigate_to_ui(app: &tauri::AppHandle) {
    update_status(app, "服务已就绪", false, true);
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.eval(&format!("location.replace('http://127.0.0.1:{PORT}/')"));
        let _ = w.show();
        let _ = w.set_focus();
    }
}

/// 重启服务（托盘菜单）
fn restart_service(app: &tauri::AppHandle) {
    let state: tauri::State<DshState> = app.state();
    if let Some(child) = state.child.lock().unwrap().take() {
        kill_tree(child.id() as u32);
    }
    // 等端口释放，避免 EADDRINUSE
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    while port_ready() && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(400));
    }
    std::thread::sleep(Duration::from_secs(1));
    set_status(app, "正在重启服务…", false);
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.eval("location.replace('index.html')");
        let _ = w.show();
    }
    match resolve_launch(app).and_then(spawn_dsh) {
        Ok(child) => {
            *state.child.lock().unwrap() = Some(child);
            if wait_port_ready(Duration::from_secs(BOOT_TIMEOUT_SECS)) {
                navigate_to_ui(app);
            } else {
                set_status(app, "重启后服务未就绪，请查看日志。", true);
            }
        }
        Err(e) => set_status(app, &e, true),
    }
}

/* ───────────────────── 服务守护 ───────────────────── */

fn watch_child(app: &tauri::AppHandle) {
    loop {
        std::thread::sleep(Duration::from_secs(3));
        let state: tauri::State<DshState> = app.state();
        let exited = {
            let mut guard = state.child.lock().unwrap();
            match guard.as_mut() {
                None => false, // 尚未启动或已被接管/退出
                Some(child) => matches!(child.try_wait(), Ok(Some(_))),
            }
        };
        if !exited {
            continue;
        }
        // 子进程意外退出：清空句柄，按次数上限自动重启
        state.child.lock().unwrap().take();
        let mut restarts = state.restarts.lock().unwrap();
        if *restarts >= MAX_AUTO_RESTARTS {
            set_status(app, "服务多次异常退出，已停止自动重启，请查看日志。", true);
            return;
        }
        *restarts += 1;
        let n = *restarts;
        drop(restarts);
        set_status(app, &format!("服务异常退出，正在自动重启（第 {n} 次）…"), false);
        match resolve_launch(app).and_then(spawn_dsh) {
            Ok(child) => {
                *state.child.lock().unwrap() = Some(child);
            }
            Err(e) => {
                set_status(app, &e, true);
                return;
            }
        }
    }
}

/* ───────────────────── 托盘 ───────────────────── */

fn build_tray(app: &tauri::AppHandle) -> tauri::Result<()> {
    use tauri_plugin_autostart::ManagerExt;

    let show = MenuItem::with_id(app, "show", "显示 / 隐藏", true, None::<&str>)?;
    let restart = MenuItem::with_id(app, "restart", "重启服务", true, None::<&str>)?;
    let autostart = CheckMenuItem::with_id(
        app,
        "autostart",
        "开机自启",
        app.autolaunch().is_enabled().unwrap_or(false),
        true,
        None::<&str>,
    )?;
    let sep = PredefinedMenuItem::separator(app)?;
    let quit = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&show, &restart, &autostart, &sep, &quit])?;

    let mut tray = TrayIconBuilder::with_id("dsh-tray")
        .icon(app.default_window_icon().expect("缺少应用图标").clone())
        .tooltip("数字分身 — 双击打开；右键菜单退出")
        .menu(&menu)
        .show_menu_on_left_click(false);

    // macOS 菜单栏习惯：单击即弹菜单（Windows 保持左键穿透、双击唤起窗口）
    #[cfg(target_os = "macos")]
    {
        tray = tray.show_menu_on_left_click(true);
    }

    tray.on_menu_event(|app, event| match event.id().as_ref() {
            "show" => {
                if let Some(w) = app.get_webview_window("main") {
                    if w.is_visible().unwrap_or(false) {
                        let _ = w.hide();
                    } else {
                        let _ = w.show();
                        let _ = w.set_focus();
                    }
                }
            }
            "restart" => {
                let handle = app.clone();
                std::thread::spawn(move || restart_service(&handle));
            }
            "autostart" => {
                use tauri_plugin_autostart::ManagerExt;
                let autolaunch = app.autolaunch();
                let enabled = autolaunch.is_enabled().unwrap_or(false);
                let result = if enabled {
                    autolaunch.disable()
                } else {
                    autolaunch.enable()
                };
                if let Err(e) = result {
                    eprintln!("切换开机自启失败: {e}");
                }
            }
            "quit" => {
                app.exit(0);
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            // 左键双击托盘：显示窗口
            if let tauri::tray::TrayIconEvent::DoubleClick { .. } = event {
                let app = tray.app_handle().clone();
                if let Some(w) = app.get_webview_window("main") {
                    let _ = w.show();
                    let _ = w.set_focus();
                }
            }
        })
        .build(app)?;
    Ok(())
}
