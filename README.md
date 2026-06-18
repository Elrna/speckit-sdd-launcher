# SDD 開発ループ環境

Spec-Kit を使った **Spec-Driven Development (SDD)** のループ環境を、フォルダを選ぶだけで構築する
デスクトップアプリです。本体は [sdd-launcher/](sdd-launcher/) にあります。

## 概要

1. **SDD Launcher**（Tauri 製アプリ）を起動
2. プロジェクトフォルダを選択
3. ボタン一つで Spec-Kit を初期化し、Claude Code 用の **`/SDD` コマンド** を配置
4. 以後そのフォルダを Claude Code で開き **`/SDD`** を実行すると、
   仕様作成（`constitution → specify → clarify → plan → tasks`）を**形式承認なしで連続実行**し、
   **各ステップ後にサブエージェントが不確定情報を点検**して意向確認が要る論点だけ `AskUserQuestion` で確認、
   **実装前に一度だけ内容を説明して承認を取り**、承認後に `implement` を実行

コマンドを 1 つずつ手で打つ必要はありません。

## クイックスタート

```bash
cd sdd-launcher
npm install
npm run tauri dev      # アプリ起動（開発）
# または
npm run tauri build    # 配布用インストーラを生成
```

詳細は [sdd-launcher/README.md](sdd-launcher/README.md) を参照してください。
