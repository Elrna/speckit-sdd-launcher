#requires -Version 5.1
# post-edit-check.ps1 — PostToolUse (Write|Edit) フック
#
# Write/Edit がテストファイルに触れたとき、そのファイルに `SPEC:` 注釈が無ければ
# additionalContext として警告を返す（トレーサビリティの取り締まり）。
#
# 素通り条件（いずれも exit 0・出力なし）:
#   - specs/ が無い（SDD フロー外）
#   - 対象がテストファイルでない / Markdown / specs 配下
#   - 既に SPEC: 注釈がある
#
# stdin から Claude Code のフック入力 JSON を受け取る。
# Windows PowerShell 5.1 互換。

$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
$data = $null
if ($raw) {
    try { $data = $raw | ConvertFrom-Json } catch { $data = $null }
}

$root = $env:CLAUDE_PROJECT_DIR
if (-not $root -and $data) { $root = $data.cwd }
if (-not $root) { $root = (Get-Location).Path }

# SDD フロー外は素通り
$specsDir = Join-Path $root 'specs'
if (-not (Test-Path -LiteralPath $specsDir)) { exit 0 }

$file = $null
if ($data -and $data.tool_input) { $file = $data.tool_input.file_path }
if (-not $file) { exit 0 }

$ext = [System.IO.Path]::GetExtension($file)
if ($ext -eq '.md') { exit 0 }
if ($file -match '(?i)[\\/]specs[\\/]') { exit 0 }

$name = [System.IO.Path]::GetFileNameWithoutExtension($file)
$testNamePattern = '(?i)(^test|test$|_test|test_|\.test\b|\.spec\b|^spec|spec$|_spec|spec_)'
if ($name -notmatch $testNamePattern) { exit 0 }

if (-not (Test-Path -LiteralPath $file)) { exit 0 }
$content = Get-Content -Raw -LiteralPath $file
if ($content -and $content -match 'SPEC:') { exit 0 }

# SPEC: 注釈が無い -> 警告を Claude に渡す
$msg = "警告: テストファイル '$name' に SPEC: 注釈がありません。各テストに、検証対象の仕様項目 ID を `SPEC: FR-001` の形式でコメント等に明記してください（G3 トレーサビリティ。trace-lint.ps1 が捏造・検証漏れを検査します）。"
$out = @{
    hookSpecificOutput = @{
        hookEventName     = 'PostToolUse'
        additionalContext = $msg
    }
}
$out | ConvertTo-Json -Compress -Depth 5
exit 0
