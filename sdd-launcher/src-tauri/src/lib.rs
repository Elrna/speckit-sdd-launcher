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

/// 生成コードに適用するコーディングポリシー（ビルド時に埋め込む）。
const CODING_POLICY: &str = include_str!("../templates/coding-policy.md");

/// 機械的執行レイヤー: hooks 定義とスクリプト（ビルド時に埋め込む）。
const SETTINGS_JSON: &str = include_str!("../templates/settings.json");
const HOOK_TRACE_LINT: &str = include_str!("../templates/trace-lint.ps1");
const HOOK_POST_EDIT: &str = include_str!("../templates/post-edit-check.ps1");
const HOOK_STOP_GATE: &str = include_str!("../templates/stop-gate.ps1");

/// CLAUDE.md に追記するポリシー参照ブロックの目印（再実行時の重複追記を防ぐ）。
const POLICY_MARKER: &str = "<!-- SDD-CODING-POLICY -->";

/// settings.json に本アプリの hooks が既に登録済みかを判定する目印
/// （再セットアップで重複登録しないための冪等性キー）。
const HOOKS_MARKER: &str = "stop-gate.ps1";

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

/// コーディングポリシーを `.specify/memory/coding-policy.md` に配置し、
/// プロジェクト直下の `CLAUDE.md` から `@import` で参照させる（再実行しても重複しない）。
fn write_coding_policy(window: &Window, path: &Path) -> Result<(), String> {
    // 1. 正本ファイルを配置
    let memory_dir = path.join(".specify").join("memory");
    std::fs::create_dir_all(&memory_dir)
        .map_err(|e| format!(".specify/memory の作成に失敗: {e}"))?;
    let policy_path = memory_dir.join("coding-policy.md");
    std::fs::write(&policy_path, CODING_POLICY)
        .map_err(|e| format!("coding-policy.md の書き込みに失敗: {e}"))?;
    emit_log(
        window,
        "info",
        &format!("コーディングポリシーを配置しました: {}", policy_path.display()),
    );

    // 2. CLAUDE.md から参照（未追記の場合のみ）
    let claude_md = path.join("CLAUDE.md");
    let existing = std::fs::read_to_string(&claude_md).unwrap_or_default();
    if existing.contains(POLICY_MARKER) {
        emit_log(window, "info", "CLAUDE.md は既にポリシーを参照済みです。");
        return Ok(());
    }
    let block = format!(
        "\n{POLICY_MARKER}\n## コーディングポリシー（必須）\n\
         このプロジェクトで生成・編集するすべてのコードは、次の設計ポリシーに必ず従うこと。\n\
         @.specify/memory/coding-policy.md\n"
    );
    let mut content = existing;
    if !content.is_empty() && !content.ends_with('\n') {
        content.push('\n');
    }
    content.push_str(&block);
    std::fs::write(&claude_md, content)
        .map_err(|e| format!("CLAUDE.md への参照追記に失敗: {e}"))?;
    emit_log(
        window,
        "info",
        "CLAUDE.md にコーディングポリシーの参照を追記しました。",
    );
    Ok(())
}

/// 既存の settings.json（Value）に、テンプレート側 hooks の各イベント配列を追記する。
/// 既存イベントがあれば配列末尾に足し、無ければ新設する。既存エントリは壊さない。
fn merge_hooks(existing: &mut serde_json::Value, template_hooks: &serde_json::Value) {
    let obj = match existing.as_object_mut() {
        Some(o) => o,
        None => return,
    };
    // 既存に "hooks" オブジェクトが無ければ用意する。
    if !obj.get("hooks").map(|h| h.is_object()).unwrap_or(false) {
        obj.insert("hooks".to_string(), serde_json::json!({}));
    }
    let dest_hooks = obj
        .get_mut("hooks")
        .and_then(|h| h.as_object_mut())
        .expect("hooks は直前でオブジェクトを保証済み");

    if let Some(src) = template_hooks.as_object() {
        for (event, entries) in src {
            let src_arr = match entries.as_array() {
                Some(a) => a,
                None => continue,
            };
            match dest_hooks.get_mut(event).and_then(|e| e.as_array_mut()) {
                Some(dest_arr) => {
                    for e in src_arr {
                        dest_arr.push(e.clone());
                    }
                }
                None => {
                    dest_hooks.insert(event.clone(), serde_json::Value::Array(src_arr.clone()));
                }
            }
        }
    }
}

/// 機械的執行レイヤー（trace-lint / post-edit-check / stop-gate と settings.json）を配置する。
/// settings.json は既存があれば安全にマージし、既に登録済みなら何もしない（冪等）。
fn write_hooks(window: &Window, path: &Path) -> Result<(), String> {
    // 1. hooks スクリプトを配置（本アプリ管理ファイルなので毎回上書き）。
    let hooks_dir = path.join(".claude").join("hooks");
    std::fs::create_dir_all(&hooks_dir).map_err(|e| format!(".claude/hooks の作成に失敗: {e}"))?;
    for (name, body) in [
        ("trace-lint.ps1", HOOK_TRACE_LINT),
        ("post-edit-check.ps1", HOOK_POST_EDIT),
        ("stop-gate.ps1", HOOK_STOP_GATE),
    ] {
        std::fs::write(hooks_dir.join(name), body)
            .map_err(|e| format!("{name} の書き込みに失敗: {e}"))?;
    }
    emit_log(window, "info", "検証 hooks スクリプトを配置しました: .claude/hooks/");

    // 2. settings.json をマージ配置。
    let settings_path = path.join(".claude").join("settings.json");
    let template: serde_json::Value = serde_json::from_str(SETTINGS_JSON)
        .map_err(|e| format!("埋め込み settings.json のパースに失敗: {e}"))?;

    if !settings_path.exists() {
        std::fs::write(&settings_path, SETTINGS_JSON)
            .map_err(|e| format!("settings.json の書き込みに失敗: {e}"))?;
        emit_log(window, "info", ".claude/settings.json を作成しました。");
        return Ok(());
    }

    // 既存あり。
    let existing_text = std::fs::read_to_string(&settings_path)
        .map_err(|e| format!("settings.json の読み込みに失敗: {e}"))?;
    if existing_text.contains(HOOKS_MARKER) {
        emit_log(window, "info", ".claude/settings.json は既に検証 hooks を登録済みです。");
        return Ok(());
    }
    let mut existing: serde_json::Value = match serde_json::from_str(&existing_text) {
        Ok(v) => v,
        Err(e) => {
            // パース不能なら壊さずスキップ（警告のみ）。
            emit_log(
                window,
                "warn",
                &format!(
                    "既存の .claude/settings.json をパースできません（{e}）。hooks の登録をスキップしました。手動でマージしてください。"
                ),
            );
            return Ok(());
        }
    };
    if !existing.is_object() {
        emit_log(
            window,
            "warn",
            "既存の .claude/settings.json がオブジェクトではありません。hooks の登録をスキップしました。",
        );
        return Ok(());
    }

    let template_hooks = template.get("hooks").cloned().unwrap_or(serde_json::json!({}));
    merge_hooks(&mut existing, &template_hooks);
    let merged = serde_json::to_string_pretty(&existing)
        .map_err(|e| format!("マージ後 settings.json の直列化に失敗: {e}"))?;
    std::fs::write(&settings_path, merged)
        .map_err(|e| format!("settings.json の書き込みに失敗: {e}"))?;
    emit_log(
        window,
        "info",
        "既存の .claude/settings.json に検証 hooks をマージしました。",
    );
    Ok(())
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

        // 3. コーディングポリシーを配置（生成コードに常時適用）
        write_coding_policy(&w, path)?;

        // 4. 機械的執行レイヤー（検証 hooks + settings.json）を配置
        write_hooks(&w, path)?;

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

#[cfg(test)]
mod tests {
    use super::*;

    /// 埋め込み settings.json は正しい JSON であり、目印を含む。
    #[test]
    fn template_settings_is_valid_and_marked() {
        let v: serde_json::Value = serde_json::from_str(SETTINGS_JSON).unwrap();
        assert!(v.get("hooks").and_then(|h| h.get("Stop")).is_some());
        assert!(SETTINGS_JSON.contains(HOOKS_MARKER));
    }

    /// 既存 hooks を持つ設定へマージすると、既存を壊さず末尾に追記される。
    #[test]
    fn merge_preserves_existing_and_appends() {
        let mut existing = serde_json::json!({
            "permissions": { "allow": ["Bash"] },
            "hooks": {
                "PostToolUse": [ { "matcher": "Read", "hooks": [] } ]
            }
        });
        let template: serde_json::Value = serde_json::from_str(SETTINGS_JSON).unwrap();
        let template_hooks = template.get("hooks").cloned().unwrap();
        merge_hooks(&mut existing, &template_hooks);

        // 既存の非 hooks 設定は保持される。
        assert_eq!(existing["permissions"]["allow"][0], "Bash");
        // 既存 PostToolUse エントリ + テンプレートの 1 件で 2 件になる。
        assert_eq!(existing["hooks"]["PostToolUse"].as_array().unwrap().len(), 2);
        assert_eq!(existing["hooks"]["PostToolUse"][0]["matcher"], "Read");
        // Stop は新設される。
        assert!(existing["hooks"]["Stop"].is_array());
        // マージ後テキストに目印が入る = 次回実行はスキップされる（冪等）。
        let text = serde_json::to_string(&existing).unwrap();
        assert!(text.contains(HOOKS_MARKER));
    }

    /// hooks キーが無い設定にもマージできる。
    #[test]
    fn merge_into_settings_without_hooks() {
        let mut existing = serde_json::json!({ "model": "opus" });
        let template: serde_json::Value = serde_json::from_str(SETTINGS_JSON).unwrap();
        let template_hooks = template.get("hooks").cloned().unwrap();
        merge_hooks(&mut existing, &template_hooks);
        assert_eq!(existing["model"], "opus");
        assert!(existing["hooks"]["Stop"].is_array());
        assert!(existing["hooks"]["PostToolUse"].is_array());
    }
}
