#requires -Version 5.1
# stop-gate.ps1 — Stop フック（テスト実行ゲート）
#
# Claude が応答を終えようとしたとき:
#   1. trace-lint.ps1 でトレーサビリティを検査する
#   2. .specify/memory/test-command.txt があればテストスイートを実行する
# いずれかに失敗があれば exit 2 でブロックし、理由を stderr で Claude に返す
#（＝テストが失敗したまま作業を終えられない、を機械的に強制）。
#
# 素通り条件（exit 0）:
#   - specs/ が無い（SDD フロー外）
#   - stop_hook_active（既にこのフックで継続中 -> 無限ブロック防止）
#
# stdin から Claude Code のフック入力 JSON を受け取る。
# Windows PowerShell 5.1 互換。

$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
$data = $null
if ($raw) {
    try { $data = $raw | ConvertFrom-Json } catch { $data = $null }
}

# 無限ブロック防止: 既にこのフックの差し戻しで再実行中なら素通り
if ($data -and $data.stop_hook_active) { exit 0 }

$root = $env:CLAUDE_PROJECT_DIR
if (-not $root -and $data) { $root = $data.cwd }
if (-not $root) { $root = (Get-Location).Path }

# SDD フロー外は素通り
$specsDir = Join-Path $root 'specs'
if (-not (Test-Path -LiteralPath $specsDir)) { exit 0 }

$problems = @()

# 1. トレーサビリティ検査
$traceScript = Join-Path $root '.claude/hooks/trace-lint.ps1'
if (Test-Path -LiteralPath $traceScript) {
    $traceOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $traceScript -ProjectRoot $root
    if ($LASTEXITCODE -ne 0) {
        $problems += ("トレーサビリティ検査に失敗しました:`n" + (($traceOut) -join "`n"))
    }
}

# 2. テストスイート実行（記録されたコマンドがあれば）
$cmdFile = Join-Path $root '.specify/memory/test-command.txt'
if (Test-Path -LiteralPath $cmdFile) {
    $testCmd = (Get-Content -Raw -LiteralPath $cmdFile).Trim()
    if ($testCmd) {
        Push-Location $root
        try {
            $testOut = cmd /c "$testCmd 2>&1"
            $testExit = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }
        if ($testExit -ne 0) {
            $tail = (@($testOut) | Select-Object -Last 40) -join "`n"
            $problems += ("テストスイート ($testCmd) が失敗しました (exit $testExit):`n$tail")
        }
    }
}

if ($problems.Count -gt 0) {
    $message = "作業を終了できません。次の問題を解決してから停止してください:`n`n" + ($problems -join "`n`n")
    [Console]::Error.WriteLine($message)
    exit 2
}

exit 0
