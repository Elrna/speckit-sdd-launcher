# Example-First 開発フロー — GitHub Copilot セットアップ & 運用指示書

**対象**: GitHub Copilot（VS Code / agent mode / Claude Opus 4.8）
**使い方（人間向け）**: Copilot Chat を agent mode にし、このファイルを開いた状態で「このドキュメントの Part 1 に従ってリポジトリをセットアップして」と指示する。セットアップは1回だけ。以後は `/ef` プロンプト（または通常のチャット）で Part 2 のフローが自動的に適用される。

---

## Part 1: セットアップ指示（Copilot への作業指示）

あなた（GitHub Copilot）は、このリポジトリに以下の5つのファイルを **記載どおりの内容で** 作成せよ。既存ファイルがある場合は上書きせず、差分を人間に提示して確認を取ること。作成後、「検証手順」を実行して動作を確認せよ。

### 1-1. `.github/copilot-instructions.md`（常時適用されるリポジトリ指示）

````markdown
# Example-First 開発ルール

このリポジトリの開発は Example-First フローに従う。あなた（Copilot）への常時ルール:

## 言語
ユーザーに見せる出力・ドキュメント・コミットメッセージはすべて日本語。コード・識別子・ファイルパスは英語のままでよい。

## フロー（要旨）
1. **入口判定**: 依頼が「挙動を新しく決める必要がある」ものか判断する。既存修正・自明な変更なら直接実装してよい（ただし完了条件は守る）。新規ツール・新しい挙動なら、実装前に必ず「具体例セッション」を行う。
2. **具体例セッション**: 実装を始める前に、次の4点を1つのメッセージで提示し、**ユーザーの承認を待つ**（承認前にコードを書いてはならない）:
   - ① ゴール1行
   - ② 要求リスト — `REQ-01` 形式の連番。各1行・検証可能な文（「〜できること」「〜で失敗すること」）
   - ③ 具体例表 — 5〜10件。列は［#（EX-01形式）/ 対応REQ / 種別（正常・境界・エラー）/ 入力 / 期待結果］。抽象語でなく**実際の値**を書く
   - ④ やらないこと（non-goals）— 対応しない入力・機能を明記する
   承認されたら内容を `examples.md`（リポジトリルート）に保存する。
3. **TDD実装**: 具体例をそのままテスト化する → 実行して**失敗を確認**してから実装する → テストが通る最小の実装 → リファクタリング。
4. **仕上げ**: README.md（何をする・使い方・制約）を作成/更新し、下記の完了条件をすべて満たしてから完了を報告する。

## テストの絶対規則
- **各テストには、検証対象の要求 ID をコメントで必ず記す**。形式は言語のコメント記法 + `REQ-xx`（例: MATLAB `% REQ-01`、Python `# REQ-01`、C系 `// REQ-01`）。
- **テストを通すためにテストを弱めることは絶対にしない**（アサーションの緩和・削除・スキップは禁止）。テストと要求が食い違うなら、実装を止めてユーザーに報告する。
- 承認済みの具体例を黙って削除・変更しない。変更が必要なら差分を示して承認を取り直す。

## 完了条件（すべて満たすまで「完了」と言ってはならない）
1. `powershell -NoProfile -ExecutionPolicy Bypass -File tools/ef-trace-lint.ps1` が成功する（全 REQ にテストがあり、テストが実在しない REQ を参照していない）。
2. `tools/test-command.txt` に記録されたコマンドでテストスイート全体を実行し、全テストが成功する。テストコマンド未記録なら、技術スタックから特定して同ファイルに1行で記録してから実行する。
3. 上記2つの**実行結果の出力を確認した**うえで完了を報告する（実行せずに「通るはず」と報告することを禁じる）。

## 文章の規則（ドキュメント・要求リスト）
意味が文脈依存で揺れる語を使わない: 「コア」「薄いラップ」「適切に」「柔軟に」「必要に応じて」「基本的に」「原則として」「可能な限り」「十分に」「シンプルな」「軽量な」「堅牢な」「シームレスに」。これらを書きたくなったら、具体的な条件・数値・責務に置き換える。名前が必要なものは固有名で呼ぶ（例: 「コア」ではなく「◯◯モジュール」）。

## 実装の規則（YAGNI）
要求リストと具体例に無い機能・設定・抽象化・「将来のための」拡張点は書かない。ただし、信頼境界の検証・データ損失防止・セキュリティに関わる処理は要求に明示がなくても省略しない。

## 差し戻し規則（最優先）
どの工程でも「要求どおりだが明らかに変だ」と感じたら、そのまま進めず停止し、該当する要求・違和感の内容・代案をユーザーに提示する。要求は従うべき聖典ではなく、反証可能な仮説である。ただし「好みの問題」程度では発動しない。
````

### 1-2. `.github/prompts/ef.prompt.md`（`/ef` で呼び出すフロー進行プロンプト）

````markdown
---
mode: agent
description: Example-First フローで新しいツール・機能を開発する
---

Example-First フローを開始する。ユーザーの要求: ${input}

手順:
1. 要求が空なら「何を作るか・何のために使うか」を1〜2問だけ確認する。
2. `.github/copilot-instructions.md` のフローに従い、具体例セッション（ゴール1行・要求リスト REQ-xx・具体例表・non-goals）を1つのメッセージで提示し、承認を待つ。**承認前に実装しない。**
3. 承認後、内容を `examples.md` に保存し、TDD（テスト先行 → 失敗確認 → 最小実装 → リファクタリング）で実装する。各テストに `REQ-xx` 注釈を付ける。
4. 完了条件（trace-lint 成功・全テスト成功・README 更新）をすべて満たしてから、要求⇔テスト対応表（`req-trace-matrix.md`）と併せて結果を報告する。
````

### 1-3. `tools/ef-trace-lint.ps1`（要求⇔テストの機械検査 + 対応表生成）

````powershell
#requires -Version 5.1
# ef-trace-lint.ps1 — examples.md の REQ 定義とテストの REQ 注釈を相互参照する。
#   検証漏れ: どのテストからも参照されない REQ
#   捏造参照: examples.md に存在しない REQ を参照するテスト
# 成功時 exit 0、問題あり exit 1。req-trace-matrix.md に対応表を出力する。
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { (Get-Location).Path }
$examples = Join-Path $root 'examples.md'
if (-not (Test-Path -LiteralPath $examples)) { Write-Output "examples.md が無いため素通り"; exit 0 }

$reqPattern = 'REQ-\d{2,}'
$defined = [System.Collections.Generic.SortedSet[string]]::new()
$reqText = @{}
foreach ($line in (Get-Content -LiteralPath $examples -Encoding UTF8)) {
    foreach ($m in [regex]::Matches($line, $reqPattern)) {
        if ($defined.Add($m.Value)) { $reqText[$m.Value] = $line.Trim() }
    }
}
if ($defined.Count -eq 0) { Write-Output "examples.md に REQ 定義が無いため素通り"; exit 0 }

$testNamePattern = '(?i)(^test|test$|_test|test_|\.test\.|\.spec\.|^spec|_spec|Test\.m$|^test.*\.m$)'
$excludeDirs = '(?i)[\\/](node_modules|\.git|\.specify|target|dist|build|vendor)[\\/]'
$refs = @{}   # REQ -> list of "file: count"
$bogus = @{}  # REQ -> list of files
Get-ChildItem -Path $root -Recurse -File | Where-Object {
    $_.FullName -notmatch $excludeDirs -and
    $_.Extension -notin @('.md') -and
    [System.IO.Path]::GetFileName($_.Name) -match $testNamePattern
} | ForEach-Object {
    $content = Get-Content -Raw -LiteralPath $_.FullName -Encoding UTF8
    $rel = $_.FullName.Substring($root.Length).TrimStart('\','/')
    $found = [regex]::Matches($content, $reqPattern) | ForEach-Object { $_.Value } | Sort-Object -Unique
    foreach ($id in $found) {
        if ($defined.Contains($id)) {
            if (-not $refs.ContainsKey($id)) { $refs[$id] = @() }
            $refs[$id] += $rel
        } else {
            if (-not $bogus.ContainsKey($id)) { $bogus[$id] = @() }
            $bogus[$id] += $rel
        }
    }
}

$missing = @($defined | Where-Object { -not $refs.ContainsKey($_) })
$lines = @("# 要求⇔テスト対応表", "", "| 要求 | 定義（examples.md） | 検証するテスト | 状態 |", "|---|---|---|---|")
foreach ($id in $defined) {
    $t = if ($refs.ContainsKey($id)) { ($refs[$id] | Sort-Object -Unique) -join '<br/>' } else { '—' }
    $st = if ($refs.ContainsKey($id)) { 'OK' } else { '**検証漏れ**' }
    $lines += "| $id | $($reqText[$id] -replace '\|','\|') | $t | $st |"
}
Set-Content -LiteralPath (Join-Path $root 'req-trace-matrix.md') -Value ($lines -join "`n") -Encoding UTF8

$ok = $true
if ($missing.Count -gt 0) { $ok = $false; Write-Output "検証漏れ（テストが無い要求）: $($missing -join ', ')" }
if ($bogus.Count -gt 0)   { $ok = $false; Write-Output "捏造参照（examples.md に無い REQ を参照）: $(($bogus.Keys | Sort-Object) -join ', ')" }
if ($ok) { Write-Output "trace-lint OK: $($defined.Count) 件の要求すべてにテストあり（req-trace-matrix.md 更新済み）"; exit 0 } else { exit 1 }
````

### 1-4. Git pre-commit フック（機械的な最終防衛線）

`.githooks/pre-commit` を作成（拡張子なし・改行は LF）:

````sh
#!/bin/sh
# Example-First の機械検査。失敗したらコミットさせない。
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/ef-trace-lint.ps1 || exit 1
if [ -f tools/test-command.txt ]; then
  cmd=$(cat tools/test-command.txt)
  echo "テスト実行: $cmd"
  eval "$cmd" || exit 1
fi
````

作成後に有効化する: `git config core.hooksPath .githooks`
（AI がどう振る舞おうと、trace-lint とテストを通らないコードはコミットできない。これが Claude Code の Stop フックに相当する層になる。）

### 1-5. `docs/examples-template.md`（具体例セッションの雛形）

````markdown
# <ツール名> — 仕様（Example-First）

**ゴール**: <1行>

## 要求リスト
- **REQ-01** — <検証可能な文。「〜できること」「〜で失敗すること」>
- **REQ-02** — <…>

## 具体例
| # | 要求 | 種別 | 入力 | 期待結果 |
|---|---|---|---|---|
| EX-01 | REQ-01 | 正常 | <実際の値> | <実際の値> |
| EX-02 | REQ-01 | 境界 | <…> | <…> |
| EX-03 | REQ-02 | エラー | <…> | <exit code とメッセージまで書く> |

## やらないこと（non-goals）
- <対応しない入力・機能>
````

### 検証手順（セットアップ後に必ず実行）

1. `powershell -NoProfile -ExecutionPolicy Bypass -File tools/ef-trace-lint.ps1` → 「examples.md が無いため素通り」と出て exit 0 になること。
2. `docs/examples-template.md` を `examples.md` にコピーし REQ-01 だけ残す → trace-lint が「検証漏れ: REQ-01」で exit 1 になること。確認後 `examples.md` と `req-trace-matrix.md` を削除。
3. `git config core.hooksPath` が `.githooks` を返すこと。

---

## Part 2: 運用（人間向けの説明）

- **新しいツールを作るとき**: Copilot Chat で `/ef <作りたいものの1〜2文>`。具体例セッションの1画面が出るので、実値を見て OK / 修正を返す。承認後は Copilot が TDD で実装し、完了時に要求⇔テスト対応表を出す。
- **既存ツールの修正**: 普通にチャットで頼めばよい。copilot-instructions.md の完了条件（trace-lint + テスト成功の実行確認）は常に適用される。
- **上への報告・監査対応**: `examples.md`（要求リスト）、`req-trace-matrix.md`（要求⇔テスト対応表・自動生成）、テスト実行結果の3点を提示する。「全テストが要求に遡れ、全要求がテストで検証されている」ことをスクリプトが機械的に保証している、と説明できる。
- **フローの一文説明**: 「要求を1行ずつ検証可能な文で定め、具体例で挙動を合意してから実装し、全テストを要求IDに紐付けて機械検証する」。
- **注意（Copilot の限界）**: Copilot には Claude Code の hooks のような「応答のたびに強制実行される検査」が無い。instructions への記載は確率的にしか守られないため、**機械的な保証は pre-commit フックが担う**。コミット前に必ず trace-lint とテストが走り、失敗すればコミットできない。
