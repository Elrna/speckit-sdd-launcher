# SDD 開発ループ環境

Spec-Kit を使った **Spec-Driven Development (SDD)** のループ環境を、フォルダを選ぶだけで構築する
デスクトップアプリです。本体は [sdd-launcher/](sdd-launcher/) にあります。

## 概要

1. **SDD Launcher**（Tauri 製アプリ）を起動
2. プロジェクトフォルダを選択
3. ボタン一つで Spec-Kit を初期化し、Claude Code 用の **`/SDD` コマンド** を配置
4. 以後そのフォルダを Claude Code で開き **`/SDD`** を実行すると、
   `constitution → specify → clarify → plan → tasks → implement` を
   **各フェーズ完了ごとに `AskUserQuestion` で確認しながら自動ループ実行**

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
