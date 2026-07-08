# SDD 開発ループ環境

Spec-Kit を使った **Spec-Driven Development (SDD)** のループ環境を、フォルダを選ぶだけで構築する
デスクトップアプリです。本体は [sdd-launcher/](sdd-launcher/) にあります。

## 概要

1. **SDD Launcher**（Tauri 製アプリ）を起動
2. プロジェクトフォルダを選択
3. ボタン一つで Spec-Kit を初期化し、Claude Code 用の **`/SDD` コマンド**・**検証 hooks**
   （`.claude/settings.json` + `.claude/hooks/`）・コーディングポリシーを配置
4. 以後そのフォルダを Claude Code で開き **`/SDD`** を実行すると、
   **Validation-Gated SDD+TDD** のフローが一括実行されます:
   - 仕様作成（`constitution → specify → clarify → plan → tasks`）を**形式承認なしで連続実行**。
     各要件に出典タグ（`[USER]`/`[DECIDED]`/`[INFERRED]`）を付与し、
     各ステップ後にサブエージェントが不確定情報を点検、意向確認が要る論点だけ `AskUserQuestion` で確認
   - **G1 仕様妥当性ゲート**: 元の要求文だけを持つ独立サブエージェントが仕様の誤りを敵対的にレビュー
   - **G2 実装前ゲート**: 具体的な入出力例（Given/When/Then）と `[INFERRED]` 要件一覧を提示して
     **一度だけ承認**を取得
   - **TDD 実装（タスク単位サブエージェント）**: `tasks.md` の各タスクを独立サブエージェントで
     Red（失敗を確認）→ **G3 テスト・トレースチェック** → Green → Refactor。
     全工程で「仕様通りだが変なら停止して差し戻す」**差し戻し規則**が有効
   - **G4 受け入れ検証**（任意）: 仕様を経由せず、元の要求と成果物を直接突き合わせて最終確認
5. **機械的執行レイヤー（hooks）** が上記フローの検証を散文の自己規律に頼らず強制します:
   - `.claude/hooks/trace-lint.ps1` が `spec.md` の要件 ID とテストの `SPEC:` 注釈を突き合わせ、
     **捏造テスト**（仕様に無い ID を参照）と**検証漏れ**（未検証の要件）を検出
   - **PostToolUse** フック: テスト編集時に `SPEC:` 注釈の欠落を警告
   - **Stop** フック: 応答終了のたびに trace-lint とテストスイートを実行し、失敗があれば**停止をブロック**
     （`specs/` が無い作業では静かに素通り）

コマンドを 1 つずつ手で打つ必要はありません。フローの設計根拠は
[docs/validation-gated-sdd-report.md](docs/validation-gated-sdd-report.md) を参照してください。

## クイックスタート

```bash
cd sdd-launcher
npm install
npm run tauri dev      # アプリ起動（開発）
# または
npm run tauri build    # 配布用インストーラを生成
```

詳細は [sdd-launcher/README.md](sdd-launcher/README.md) を参照してください。
