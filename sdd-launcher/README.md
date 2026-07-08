# SDD Launcher

フォルダを選ぶだけで [GitHub Spec-Kit](https://github.com/github/spec-kit) を初期化し、
Claude Code 上で **`/SDD` コマンド一発** で **Validation-Gated SDD+TDD** のフロー
（仕様作成 → 仕様妥当性ゲート → 具体例ベースの承認 → TDD 実装 → 受け入れ検証）を
**一括実行**できる環境を作る Tauri デスクトップアプリです。

## できること

1. アプリ起動 → 前提条件（git / uv / Claude Code）を自動チェック
2. `uv` が無ければワンクリックで導入
3. プロジェクトフォルダを選択
4. 「初期化」ボタンで以下を自動実行
   - `uvx --from git+https://github.com/github/spec-kit.git specify init . --here --integration claude --script ps --force --ignore-agent-tools`
   - `.claude/commands/SDD.md`（`/SDD` オーケストレーターコマンド）を配置
   - `.specify/memory/coding-policy.md`（生成コードの設計ポリシー）を配置し、`CLAUDE.md` から `@import` で参照
   - **検証 hooks** を配置: `.claude/hooks/`（`trace-lint.ps1` / `post-edit-check.ps1` / `stop-gate.ps1`）と
     `.claude/settings.json`（hooks 定義。既存があれば安全にマージ・冪等）
5. 以後、そのフォルダを Claude Code で開き `/SDD` を実行するだけ

## 機械的執行レイヤー（hooks）

`/SDD` の検証（トレースチェック・テスト実行・テスト弱化の禁止）は、これまで `SDD.md` の散文指示
＝ LLM の自己規律に頼っていました。v0.4.0 からは Claude Code の hooks で**機械的に強制**します。

- **`.claude/hooks/trace-lint.ps1`** — `specs/**/spec.md` の要件 ID（`FR-001` 等）と、テストファイルの
  `SPEC: <ID>` 注釈を相互参照し、**捏造テスト**（仕様に無い ID を参照）と**検証漏れ**
  （どのテストからも参照されない要件）を検出します。
- **PostToolUse フック**（`post-edit-check.ps1`）— Write/Edit がテストファイルに触れたとき、
  `SPEC:` 注釈が無ければ警告を additionalContext として返します。
- **Stop フック**（`stop-gate.ps1`）— Claude が応答を終えるたびに trace-lint と
  `.specify/memory/test-command.txt` のテストスイートを実行し、失敗があれば `exit 2` で**停止をブロック**
  します（テストが失敗したまま作業を終えられない、を機械的に強制）。

いずれも **`specs/` が無い作業では静かに素通り**（exit 0）し、SDD フロー外での過干渉と無限ブロックを防ぎます。
スクリプトは Windows PowerShell 5.1 互換で、UTF-8 BOM 付きで配置されます。

## コーディングポリシー

セットアップ時に [templates/coding-policy.md](templates/coding-policy.md) を
`.specify/memory/coding-policy.md` として配置し、プロジェクトの `CLAUDE.md` から参照させます。
これにより **このプロジェクトで Claude Code が生成・編集するすべてのコード** に、
SRP / KISS / DRY・命名設計・カプセル化・リファクタリング鉄則・テストの設計原則（TDD 用）・
「悪い設計の臭い」チェックリスト等のポリシーが常時適用されます（`/SDD` の implement 段でも明示的に参照）。

## `/SDD` コマンドの挙動 — Validation-Gated SDD+TDD

`/SDD` は Spec-Kit の各 `speckit-*` スキル（`.claude/skills/speckit-*/SKILL.md`）を
`Skill` ツールで順に実行しつつ、**仕様そのものの検証（validation）** を仕様の前後に配置します。
TDD は「仕様通りに作れたか」しか保証できず、仕様が誤っていればその誤りを固定化してしまう——
というギャップを埋めるための構成です。

1. **仕様作成（constitution → specify → clarify → plan → tasks）は形式承認を挟まず連続実行**。
   各要件に出典タグ `[USER]`（ユーザー発言）/ `[DECIDED]`（確認済み決定）/ `[INFERRED]`（エージェントの推測）を付与。
   各フェーズ直後に読み取り専用サブエージェントが**不確定情報（不足）を点検**し、
   「妥当に推測できず、かつ仕様・設計・スコープを左右する」論点だけ `AskUserQuestion` で確認します。
2. **G1 仕様妥当性ゲート**（clarify 後）: 元の要求文と仕様書**だけ**を渡した独立サブエージェントが、
   意図との乖離・出所不明の要件・矛盾を敵対的にレビューし、**誤りを検出**します。
3. **具体例化 + G2 実装前ゲート**: 主要要件を Given/When/Then + 具体的な値の入出力例
   （`specs/<機能>/examples.md`）に書き下し、**要約ではなく具体例と `[INFERRED]` 要件一覧**を提示して
   一度だけ承認を取ります。具体例は実装フェーズで受け入れテストの雛形として再利用されます。
4. **TDD 実装（タスク単位サブエージェント）**: `tasks.md` の各タスクを Task ツールの新規サブエージェントで
   Red（失敗を確認）→ **G3 テスト・トレースチェック** → Green → Refactor。単一コンテキストの劣化を避けるため
   タスクごとに独立した実装役へ委譲し、該当タスク・関連仕様・具体例・coding-policy のみを渡す（作成過程は渡さない）。
   捏造・検証漏れの検出は `.claude/hooks/trace-lint.ps1` に委譲（hooks で機械的に強制）。テストを弱めて通すことは禁止。
5. **差し戻し規則**（全工程共通）: 「仕様通りだが明らかに変」と気づいたら実装せず停止し、
   仕様変更提案をユーザーに提示します。仕様の欠陥報告は仕様への忠実さより優先。
6. **G4 受け入れ検証**（G2 で選択時のみ）: 元の要求文だけを渡したサブエージェントが、
   仕様を経由せず成果物を直接確認します。

人間への承認は G2 の一度だけ。追加されるのはエージェント間の検証であり、
人間に届くのは検証をすり抜けられなかった論点だけです。
本体は [templates/SDD.md](templates/SDD.md)、設計根拠は
[../docs/validation-gated-sdd-report.md](../docs/validation-gated-sdd-report.md)。

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
│   ├── src/lib.rs        Tauri コマンド（前提チェック / フォルダ選択 / uv 導入 / specify 実行 / hooks 配置）
│   ├── templates/SDD.md              生成先に配置する /SDD コマンド本文（ビルド時に埋め込み）
│   ├── templates/coding-policy.md    生成コードの設計ポリシー（ビルド時に埋め込み）
│   ├── templates/settings.json       検証 hooks 定義（既存があれば安全にマージ）
│   ├── templates/trace-lint.ps1      トレーサビリティ検査スクリプト
│   ├── templates/post-edit-check.ps1 テスト編集時の SPEC 注釈チェック（PostToolUse）
│   ├── templates/stop-gate.ps1       Stop 時のテスト実行ゲート
│   ├── capabilities/     権限定義
│   ├── Cargo.toml
│   └── tauri.conf.json
└── package.json
```
