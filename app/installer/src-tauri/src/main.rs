// DSH 数字分身 GUI 安装向导
//
// 定位是 setup.{ps1,sh} 之上的薄壳：4 屏向导只负责
//   1) 收齐参数
//   2) 探测平台 + 准备可执行命令
//   3) 流式拉起子进程，把 stdout/stderr 推到前端
//   4) 安装完成后可选启动桌面宿主
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread;

use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager, State};
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

/// 前端 4 屏向导共用的参数体
#[derive(Debug, Clone, Deserialize, Serialize, Default)]
#[serde(rename_all = "camelCase")]
struct InstallRequest {
    /// 插件安装目录（默认 ~/dsh-persona）
    packages_dir: Option<String>,
    /// 企业微信 BotID（可选）
    bot_id: Option<String>,
    /// 企业微信 Secret（可选）
    secret: Option<String>,
    /// 分身信息 8 项
    owner: Option<String>,
    owner_title: Option<String>,
    owner_stance: Option<String>,
    owner_scope: Option<String>,
    owner_style: Option<String>,
    owner_address: Option<String>,
    twin_name: Option<String>,
    twin_aliases: Option<String>,
    /// 安装完是否立即启动桌面宿主
    launch_after: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum InstallEvent {
    /// 子进程 stdout/stderr 一行日志
    Log { stream: &'static str, line: String },
    /// 阶段识别（解析 `=== ... ===`）
    Phase { name: String, index: usize },
    /// 子进程退出
    Exit { code: Option<i32>, success: bool },
    /// 错误（启动失败 / 无法解析路径等）
    Error { message: String },
}

#[derive(Default)]
struct InstallState {
    child: Mutex<Option<std::process::Child>>,
}

/// 探测平台：返回 `(脚本文件名, 主参数前缀)`，与 scripts/setup.{ps1,sh} 对应
fn platform_setup() -> (&'static str, &'static str, &'static str) {
    if cfg!(windows) {
        ("setup.ps1", "-", "powershell")
    } else {
        ("setup.sh", "--", "bash")
    }
}

/// 仓库根目录：dev 模式下用 CARGO_MANIFEST_DIR 推导
/// （Tauri 打包后二进制在 bundle 里，需要靠其他方式定位；首版开发期先
/// 支持 repo 内运行，CI 在打包时把脚本拷到 Resources/_scripts_/）
fn repo_root() -> PathBuf {
    // src-tauri/src/main.rs -> ../../.. -> repo root
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.pop(); // installer
    p.pop(); // app
    p
}

/// 探测 Node 与 dsh 是否已可用（前端"环境检查"屏用）
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct PrereqReport {
    node: Option<String>,
    git: Option<String>,
    /// GitHub codeload 是否可达（HEAD 请求 5s 超时）
    network_ok: bool,
    /// 安装脚本是否存在
    setup_script_found: bool,
    repo_root: String,
}

fn command_version(cmd: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(cmd).args(args).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout);
    // node -v / git --version 第一行
    Some(s.lines().next().unwrap_or("").trim().to_string())
}

#[tauri::command]
fn check_prereq() -> PrereqReport {
    let (script, _, _) = platform_setup();
    let root = repo_root();
    let setup_path = root.join("scripts").join(script);
    let setup_script_found = setup_path.exists();

    // 探测 node（优先便携版，fallback 系统 PATH）
    let node = {
        let portable = portable_node_exe();
        if let Some(p) = portable {
            command_version(p.to_string_lossy().as_ref(), &["-v"])
        } else {
            command_version("node", &["-v"])
        }
    };

    let git = command_version("git", &["--version"]);

    // 网络探测：HEAD codeload，5s 超时
    let network_ok = probe_network();

    PrereqReport {
        node,
        git,
        network_ok,
        setup_script_found,
        repo_root: root.to_string_lossy().into_owned(),
    }
}

/// 探测便携版 Node 是否已就绪
fn portable_node_exe() -> Option<PathBuf> {
    let mut p = portable_node_root();
    if cfg!(windows) {
        p.push("node.exe");
    } else {
        p.push("bin/node");
    }
    if p.exists() { Some(p) } else { None }
}

#[cfg(windows)]
fn portable_node_root() -> PathBuf {
    let local = std::env::var("LOCALAPPDATA").unwrap_or_else(|_| ".".into());
    PathBuf::from(local).join("dsh-persona").join("node")
}
#[cfg(not(windows))]
fn portable_node_root() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    if cfg!(target_os = "macos") {
        PathBuf::from(home).join("Library/Application Support/dsh-persona/node")
    } else {
        PathBuf::from(home).join(".local/share/dsh-persona/node")
    }
}

fn probe_network() -> bool {
    // 用 curl probe（依赖 curl，win10+ 自带 curl）；不行就 fallback 一个固定域名 TCP
    #[cfg(windows)]
    let probe = Command::new("curl")
        .args([
            "-sS",
            "-o",
            "NUL",
            "--max-time",
            "5",
            "-I",
            "https://codeload.github.com/",
        ])
        .output();
    #[cfg(not(windows))]
    let probe = Command::new("curl")
        .args([
            "-sS",
            "-o",
            "/dev/null",
            "--max-time",
            "5",
            "-I",
            "https://codeload.github.com/",
        ])
        .output();
    if let Ok(o) = probe {
        return o.status.success();
    }
    false
}

/// 解析 setup.{ps1,sh} 的 stdout 阶段名（`=== <name> ===`）→ 索引
fn phase_index(name: &str) -> Option<usize> {
    // 与 scripts/setup.{ps1,sh} 当前的 Write-Step 段名保持一致；
    // 未知段名落到末尾"安装完成"。
    match name {
        "准备 Node.js 运行环境" => Some(0),
        "安装 DSH（便携版环境）" | "安装 DSH" => Some(1),
        "确定安装目录" => Some(2),
        "克隆仓库" | "获取插件仓库" => Some(3),
        "复制分身指引插件" | "构建插件" => Some(4),
        "配置 DSH Profile" | "安装依赖" => Some(5),
        "创建目录结构与数字分身预设" | "创建数字分身预设" => Some(6),
        "企业微信配置" | "MCP 服务器配置" => Some(7),
        "安装启动器" => Some(8),
        "安装完成" => Some(9),
        _ => None,
    }
}

/// 构造 setup 子进程的命令行
fn build_setup_command(req: &InstallRequest) -> Result<(Command, &'static str), String> {
    let (script, flag, exe) = platform_setup();
    let root = repo_root();
    let setup_path = root.join("scripts").join(script);
    if !setup_path.exists() {
        return Err(format!(
            "找不到安装脚本: {}（请确认从 dsh-persona 仓库根目录运行）",
            setup_path.display()
        ));
    }

    let mut cmd = Command::new(exe);
    if cfg!(windows) {
        cmd.arg("-ExecutionPolicy").arg("Bypass").arg("-File").arg(&setup_path);
    } else {
        cmd.arg(&setup_path);
    }
    cmd.arg("-NonInteractive").arg(format!("{}NonInteractive", flag));

    let mut push = |name: &str, val: &str| {
        if !val.is_empty() {
            cmd.arg(format!("{}{}", flag, name));
            cmd.arg(val);
        }
    };

    if let Some(v) = &req.packages_dir {
        push("PackagesDir", v);
    }
    if let Some(v) = &req.bot_id {
        push("BotId", v);
    }
    if let Some(v) = &req.secret {
        push("Secret", v);
    }
    if let Some(v) = &req.owner {
        push("Owner", v);
    }
    if let Some(v) = &req.owner_title {
        push("OwnerTitle", v);
    }
    if let Some(v) = &req.owner_stance {
        push("OwnerStance", v);
    }
    if let Some(v) = &req.owner_scope {
        push("OwnerScope", v);
    }
    if let Some(v) = &req.owner_style {
        push("OwnerStyle", v);
    }
    if let Some(v) = &req.owner_address {
        push("OwnerAddress", v);
    }
    if let Some(v) = &req.twin_name {
        push("TwinName", v);
    }
    if let Some(v) = &req.twin_aliases {
        push("TwinAliases", v);
    }

    if req.launch_after {
        cmd.arg(format!("{}Launch", flag));
    }

    Ok((cmd, script))
}

#[tauri::command]
fn run_setup(
    app: AppHandle,
    state: State<'_, InstallState>,
    request: InstallRequest,
) -> Result<(), String> {
    {
        let mut guard = state.child.lock();
        if guard.is_some() {
            return Err("安装已在进行中".into());
        }
        *guard = None;
    }

    let (mut cmd, _script) = build_setup_command(&request)?;
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());

    // 透传便携版 Node 路径
    if let Some(node) = portable_node_exe() {
        let node_dir = node.parent().unwrap().to_string_lossy().into_owned();
        let cur = std::env::var("PATH").unwrap_or_default();
        #[cfg(windows)]
        let sep = ";";
        #[cfg(not(windows))]
        let sep = ":";
        std::env::set_var("PATH", format!("{}{}{}", node_dir, sep, cur));
    }

    let mut child = cmd
        .spawn()
        .map_err(|e| format!("无法启动安装脚本: {}", e))?;

    let stdout = child.stdout.take().ok_or("无法获取 stdout")?;
    let stderr = child.stderr.take().ok_or("无法获取 stderr")?;

    {
        let mut guard = state.child.lock();
        *guard = Some(child);
    }

    // stdout 流线程
    {
        let app = app.clone();
        thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines().map_while(Result::ok) {
                // 识别阶段
                if let Some(name) = parse_phase(&line) {
                    if let Some(idx) = phase_index(&name) {
                        let _ = app.emit(
                            "install-event",
                            InstallEvent::Phase {
                                name: name.clone(),
                                index: idx,
                            },
                        );
                    }
                }
                let _ = app.emit(
                    "install-event",
                    InstallEvent::Log {
                        stream: "stdout",
                        line,
                    },
                );
            }
        });
    }
    // stderr 流线程
    {
        let app = app.clone();
        thread::spawn(move || {
            let reader = BufReader::new(stderr);
            for line in reader.lines().map_while(Result::ok) {
                let _ = app.emit(
                    "install-event",
                    InstallEvent::Log {
                        stream: "stderr",
                        line,
                    },
                );
            }
        });
    }

    Ok(())
}

/// 等子进程退出并向前端 emit Exit
#[tauri::command]
fn wait_setup(
    app: AppHandle,
    state: State<'_, InstallState>,
) -> Result<i32, String> {
    let child = {
        let mut guard = state.child.lock();
        guard.take()
    };
    let mut child = child.ok_or("没有正在进行的安装")?;
    let status = child.wait().map_err(|e| format!("wait 失败: {}", e))?;
    let code = status.code();
    let success = status.success();
    let _ = app.emit(
        "install-event",
        InstallEvent::Exit {
            code,
            success,
        },
    );
    Ok(code.unwrap_or(-1))
}

/// 主动取消正在进行的安装
#[tauri::command]
fn cancel_setup(state: State<'_, InstallState>) -> Result<(), String> {
    let mut guard = state.child.lock();
    if let Some(child) = guard.as_mut() {
        child.kill().map_err(|e| format!("kill 失败: {}", e))?;
    }
    *guard = None;
    Ok(())
}

/// 安装成功后启动桌面宿主（DSH Desktop.exe / .app / start-persona.sh）
#[tauri::command]
fn launch_desktop() -> Result<(), String> {
    #[cfg(windows)]
    {
        // 与 scripts/setup.ps1 同样的查找顺序
        let candidates = [
            std::env::var("LOCALAPPDATA").ok().map(|p| {
                PathBuf::from(p).join("DSH-Desktop").join("DSH-Desktop.exe")
            }),
            std::env::var("LOCALAPPDATA").ok().map(|p| {
                PathBuf::from(p).join("DSH-Desktop").join("dsh-desktop.exe")
            }),
            std::env::var("LOCALAPPDATA").ok().map(|p| {
                PathBuf::from(p).join("dsh-desktop").join("DSH-Desktop.exe")
            }),
            std::env::var("LOCALAPPDATA").ok().map(|p| {
                PathBuf::from(p).join("dsh-desktop").join("dsh-desktop.exe")
            }),
        ];
        for c in candidates.into_iter().flatten() {
            if c.exists() {
                Command::new(&c).spawn().map_err(|e| e.to_string())?;
                return Ok(());
            }
        }
        return Err("未找到 DSH Desktop；可使用启动数字分身.bat 以浏览器方式启动".into());
    }
    #[cfg(not(windows))]
    {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
        let candidates = [
            PathBuf::from(&home).join("Applications").join("DSH-Desktop.app"),
            PathBuf::from(&home).join("dsh-persona").join("dsh-persona").join("start-persona.sh"),
        ];
        for c in candidates {
            if c.exists() {
                #[cfg(target_os = "macos")]
                {
                    Command::new("open").arg(&c).spawn().map_err(|e| e.to_string())?;
                    return Ok(());
                }
                #[cfg(all(not(target_os = "macos")))]
                {
                    Command::new(&c).spawn().map_err(|e| e.to_string())?;
                    return Ok(());
                }
            }
        }
        return Err("未找到桌面应用或启动器".into());
    }
}

/// 解析 `=== <name> ===` 行，返回段名
fn parse_phase(line: &str) -> Option<String> {
    let t = line.trim();
    let t = t.trim_start_matches('=').trim_end_matches('=').trim();
    if t.is_empty() {
        return None;
    }
    // 至少包含非空白字符且不超过 64
    if t.len() > 64 {
        return None;
    }
    Some(t.to_string())
}

fn main() {
    tauri::Builder::default()
        .manage(InstallState::default())
        .invoke_handler(tauri::generate_handler![
            check_prereq,
            run_setup,
            wait_setup,
            cancel_setup,
            launch_desktop
        ])
        .setup(|app| {
            // 开发期方便：把窗口名打出来确认启动
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.set_title("DSH 数字分身 - 安装向导");
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("failed to start DSH Persona Installer");
}