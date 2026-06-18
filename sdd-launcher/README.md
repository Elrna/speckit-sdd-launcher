# SDD Launcher

フォルダを選ぶだけで [GitHub Spec-Kit](https://github.com/github/spec-kit) を初期化し、
Claude Code 上で **`/SDD` コマンド一発** で Spec-Driven Development のフロー
（constitution → specify → clarify → plan → tasks → implement）を
**各フェーズ確認付きで一括実行**できる環境を作る Tauri デスクトップアプリです。

## できること

1. アプリ起動 → 前提条件（git / uv / Claude Code）を自動チェック
2. `uv` が無ければワンクリックで導入
3. プロジェクトフォルダを選択
4. 「初期化」ボタンで以下を自動実行
   - `uvx --from git+https://github.com/github/spec-kit.git specify init . --here --integration claude --script ps --force --ignore-agent-tools`
   - `.claude/commands/SDD.md`（`/SDD` オーケストレーターコマンド）を配置
5. 以後、そのフォルダを Claude Code で開き `/SDD` を実行するだけ

## `/SDD` コマンドの挙動

`/SDD` は Spec-Kit の各 `speckit-*` スキル（`.claude/skills/speckit-*/SKILL.md`）を
`Skill` ツールで順に実行します。

- **仕様作成（constitution → specify → clarify → plan → tasks）は形式承認を挟まず連続実行**。
- **各フェーズ直後に、読み取り専用のサブエージェント（`Task`）が不確定情報を点検**。
  「エージェントが妥当に推測できず、かつ仕様・設計・スコープを左右する」論点が見つかったときだけ、
  `AskUserQuestion` でユーザーの意向を確認します（過剰に聞かないよう基準で抑制）。
- **実装に入る前に一度だけ**、作成物（仕様・計画・タスク）を日本語でまとめて説明して
  `AskUserQuestion` で承認を取り、承認後に `speckit-implement` を実行します。

コマンドを 1 つずつ手で打ったり、フェーズごとに形式承認したりする必要はありません。本体は [templates/SDD.md](templates/SDD.md)。

## 前提条件

- [Rust](https://rustup.rs/)（1.77 以上）+ MSVC ビルドツール
- [Node.js](https://nodejs.org/)（`@tauri-apps/cli` 用）
- Windows 11（WebView2 同梱）
- `uv`（未導入ならアプリ内から導入可能）
- 生成プロジェクトを使うには [Claude Code](https://claude.com/claude-code)

## 開発・実行

```bash
npm install          # 初回のみ
npm run tauri dev    # 開発起動
npm run tauri build  # 配布用ビルド（インストーラ生成）
```

## 構成

```
sdd-launcher/
├── src/                  フロントエンド（vanilla HTML/CSS/JS, バンドラ無し）
│   ├── index.html
│   ├── main.js           UI ロジック・Rust 呼び出し・ログ表示
│   └── styles.css
├── src-tauri/
│   ├── src/lib.rs        Tauri コマンド（前提チェック / フォルダ選択 / uv 導入 / specify 実行）
│   ├── templates/SDD.md  生成先に配置する /SDD コマンド本文（ビルド時に埋め込み）
│   ├── capabilities/     権限定義
│   ├── Cargo.toml
│   └── tauri.conf.json
└── package.json
```
