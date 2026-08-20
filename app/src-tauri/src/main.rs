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
        })
        .setup(|app| {
            build_tray(app.handle())?;
            // 启动序列在后台线程执行，窗口先显示加载页
            let handle = app.handle().clone();
            std::thread::spawn(move || {
                if let Err(err) = startup_sequence(&handle) {
                    let _ = handle.emit(
                        "startup-status",
                        serde_json::json!({ "text": err, "error": true }),
                    );
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
    runtime_root()
        .join("node")
        .join("node_modules")
        .join("@deepseek-ai")
        .join("dsh")
        .join("lib")
        .join("bin.js")
}

fn log_file() -> PathBuf {
    runtime_root().join("dsh-web.log")
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

fn spawn_dsh() -> Result<Child, String> {
    let node = node_exe();
    let bin = dsh_bin_js();
    if !node.exists() {
        return Err("未找到便携版 Node 运行时。请先运行 scripts/setup.ps1 完成安装。".into());
    }
    if !bin.exists() {
        return Err("未找到 DSH。请先运行 scripts/setup.ps1 完成安装。".into());
    }
    let mut log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_file())
        .map_err(|e| format!("无法写入日志文件: {e}"))?;
    let log_err = log.try_clone().map_err(|e| format!("{e}"))?;
    let _ = writeln!(log, "\n===== dsh web 由桌面应用启动 {} =====", chrono_now());

    let node_dir = node.parent().map(|p| p.to_path_buf()).unwrap_or_default();
    let path_var = if cfg!(windows) {
        let sys = std::env::var("PATH").unwrap_or_default();
        format!("{};{}", node_dir.display(), sys)
    } else {
        let sys = std::env::var("PATH").unwrap_or_default();
        format!("{}:{}", node_dir.display(), sys)
    };

    let mut cmd = Command::new(&node);
    cmd.arg(&bin)
        .arg("web")
        .env("PATH", &path_var)
        .current_dir(node_dir.clone())
        .stdin(Stdio::null())
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

fn set_status(app: &tauri::AppHandle, text: &str, error: bool) {
    let _ = app.emit(
        "startup-status",
        serde_json::json!({ "text": text, "error": error }),
    );
}

fn startup_sequence(app: &tauri::AppHandle) -> Result<(), String> {
    let state: tauri::State<DshState> = app.state();
    if port_ready() {
        // 已有实例在运行（例如开机自启后再次双击）：直接接管窗口
        set_status(app, "检测到运行中的服务，正在连接…", false);
        navigate_to_ui(app);
        return Ok(());
    }
    set_status(app, "正在启动数字分身服务…", false);
    let child = spawn_dsh()?;
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

/// 把主窗口从加载页导航到 dsh web 界面
fn navigate_to_ui(app: &tauri::AppHandle) {
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
    match spawn_dsh() {
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
        match spawn_dsh() {
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
