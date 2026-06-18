// Spec-Kit SDD ループ環境セットアップ ランチャー — Rust バックエンド
//
// 提供する Tauri コマンド:
//   - check_prerequisites : git / uv / claude の有無とバージョンを返す
//   - pick_directory      : ネイティブのフォルダ選択ダイアログを開く
//   - install_uv          : 公式インストーラで uv を導入する（出力をストリーム）
//   - run_setup           : 選択フォルダで `specify init` を実行し /SDD コマンドを配置する
//
// 進捗ログは "setup-log" イベント ({stream, line}) としてフロントへ emit する。

use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Command, Stdio};

use tauri::{Emitter, Window};

/// /SDD スラッシュコマンドの本文（ビルド時に埋め込む）。
const SDD_COMMAND: &str = include_str!("../templates/SDD.md");

/// uv の公式インストーラが配置する実行ファイルのディレクトリ (%USERPROFILE%\.local\bin)。
fn uv_bin_dir() -> Option<std::path::PathBuf> {
    std::env::var_os("USERPROFILE")
        .map(|h| std::path::PathBuf::from(h).join(".local").join("bin"))
}

/// uvx の実行ファイルパスを返す。インストール先に存在すれば絶対パス、無ければ "uvx"。
/// （Windows では Command のプログラム解決に子プロセスの PATH が使われないため、
///   絶対パスで渡すのが確実）
fn uvx_program() -> String {
    if let Some(dir) = uv_bin_dir() {
        let p = dir.join("uvx.exe");
        if p.exists() {
            return p.to_string_lossy().to_string();
        }
    }
    "uvx".to_string()
}

/// 現在の PATH に uv のインストール先を加えた文字列を返す。
/// （uv をインストールした直後でも、同一プロセスから uvx を呼べるようにするため）
fn augmented_path() -> String {
    let mut p = std::env::var("PATH").unwrap_or_default();
    if let Some(dir) = uv_bin_dir() {
        let dir = dir.to_string_lossy().to_string();
        let already = p.split(';').any(|seg| seg.eq_ignore_ascii_case(&dir));
        if !already {
            if !p.is_empty() {
                p.push(';');
            }
            p.push_str(&dir);
        }
    }
    p
}

/// 進捗ログを 1 行 emit する。
fn emit_log(window: &Window, stream: &str, line: &str) {
    let _ = window.emit(
        "setup-log",
        serde_json::json!({ "stream": stream, "line": line }),
    );
}

/// `cmd /C <prog> --version` を実行し、先頭行を返す。失敗時は None。
fn cmd_version(prog: &str) -> Option<String> {
    let out = Command::new("cmd")
        .args(["/C", &format!("{prog} --version")])
        .env("PATH", augmented_path())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    let first = stdout.lines().next().unwrap_or("").trim();
    if !first.is_empty() {
        return Some(first.to_string());
    }
    // 一部ツールは --version を stderr に出す
    let stderr = String::from_utf8_lossy(&out.stderr);
    let first = stderr.lines().next().unwrap_or("").trim();
    Some(first.to_string())
}

#[derive(serde::Serialize)]
struct Prereqs {
    git: Option<String>,
    uv: Option<String>,
    claude: Option<String>,
}

/// git / uv / claude の有無とバージョンを返す。
#[tauri::command]
fn check_prerequisites() -> Prereqs {
    Prereqs {
        git: cmd_version("git"),
        uv: cmd_version("uv"),
        claude: cmd_version("claude"),
    }
}

/// ネイティブのフォルダ選択ダイアログを開き、選ばれたパスを返す。
#[tauri::command]
async fn pick_directory() -> Option<String> {
    tauri::async_runtime::spawn_blocking(|| {
        rfd::FileDialog::new()
            .set_title("Spec-Kit を初期化するフォルダを選択")
            .pick_folder()
            .map(|p| p.to_string_lossy().to_string())
    })
    .await
    .ok()
    .flatten()
}

/// 指定プログラムを直接起動し、stdout/stderr を 1 行ずつ emit する。終了コードを返す。
/// （`cmd /C` を介さないことで、引数中の引用符やパイプの解釈ずれを避ける）
fn run_streaming(
    window: &Window,
    cwd: Option<&Path>,
    program: &str,
    args: &[&str],
) -> Result<i32, String> {
    emit_log(window, "info", &format!("$ {} {}", program, args.join(" ")));

    let mut cmd = Command::new(program);
    cmd.args(args);
    if let Some(d) = cwd {
        cmd.current_dir(d);
    }
    cmd.env("PATH", augmented_path());
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());

    let mut child = cmd.spawn().map_err(|e| format!("プロセス起動に失敗: {e}"))?;
    let stdout = child.stdout.take().ok_or("stdout を取得できません")?;
    let stderr = child.stderr.take().ok_or("stderr を取得できません")?;

    let w_out = window.clone();
    let h_out = std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            emit_log(&w_out, "stdout", &line);
        }
    });
    let w_err = window.clone();
    let h_err = std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            emit_log(&w_err, "stderr", &line);
        }
    });

    let status = child.wait().map_err(|e| format!("プロセス待機に失敗: {e}"))?;
    let _ = h_out.join();
    let _ = h_err.join();
    Ok(status.code().unwrap_or(-1))
}

/// 公式インストーラ (astral.sh) で uv を導入する。導入後のバージョン文字列を返す。
#[tauri::command]
async fn install_uv(window: Window) -> Result<String, String> {
    let w = window.clone();
    let code = tauri::async_runtime::spawn_blocking(move || {
        run_streaming(
            &w,
            None,
            "powershell",
            &[
                "-ExecutionPolicy",
                "Bypass",
                "-NoProfile",
                "-Command",
                "irm https://astral.sh/uv/install.ps1 | iex",
            ],
        )
    })
    .await
    .map_err(|e| e.to_string())??;

    if code != 0 {
        return Err(format!("uv のインストールに失敗しました (exit {code})"));
    }
    match cmd_version("uv") {
        Some(v) => Ok(v),
        None => Err(
            "uv をインストールしましたが検出できません。アプリを再起動して再試行してください。"
                .into(),
        ),
    }
}

/// 選択フォルダで Spec-Kit を初期化し、/SDD コマンドを配置する。
#[tauri::command]
async fn run_setup(window: Window, dir: String) -> Result<String, String> {
    let w = window.clone();
    let dir_for_task = dir.clone();

    let outcome = tauri::async_runtime::spawn_blocking(move || -> Result<(), String> {
        let path = Path::new(&dir_for_task);
        if !path.is_dir() {
            return Err(format!("ディレクトリが存在しません: {dir_for_task}"));
        }

        // 1. Spec-Kit を初期化（Claude Code 連携、PowerShell スクリプト、非対話）
        emit_log(&w, "info", "Spec-Kit を初期化しています (uvx specify init)...");
        let uvx = uvx_program();
        let code = run_streaming(
            &w,
            Some(path),
            &uvx,
            &[
                "--from",
                "git+https://github.com/github/spec-kit.git",
                "specify",
                "init",
                ".",
                "--here",
                "--integration",
                "claude",
                "--script",
                "ps",
                "--force",
                "--ignore-agent-tools",
            ],
        )?;
        if code != 0 {
            return Err(format!(
                "specify init が失敗しました (exit {code})。uv とネットワーク接続を確認してください。"
            ));
        }

        // 2. /SDD オーケストレーターコマンドを配置
        let cmd_dir = path.join(".claude").join("commands");
        std::fs::create_dir_all(&cmd_dir)
            .map_err(|e| format!(".claude/commands の作成に失敗: {e}"))?;
        let sdd_path = cmd_dir.join("SDD.md");
        std::fs::write(&sdd_path, SDD_COMMAND)
            .map_err(|e| format!("SDD.md の書き込みに失敗: {e}"))?;
        emit_log(
            &w,
            "info",
            &format!("/SDD コマンドを作成しました: {}", sdd_path.display()),
        );
        emit_log(
            &w,
            "info",
            "✅ セットアップ完了。Claude Code でフォルダを開き /SDD を実行してください。",
        );
        Ok(())
    })
    .await
    .map_err(|e| e.to_string())?;

    outcome?;
    Ok("セットアップが完了しました".to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            check_prerequisites,
            pick_directory,
            install_uv,
            run_setup
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
