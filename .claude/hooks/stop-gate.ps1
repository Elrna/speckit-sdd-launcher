#requires -Version 5.1
# stop-gate.ps1 — Stop フック（トレース検査 + テスト実行ゲート）
#
# Claude が応答を終えようとしたとき:
#   1. specs/ があれば trace-lint.ps1 でトレーサビリティを検査する（SDD フロー）
#   2. ルートに examples.md があれば ef-trace-lint.ps1 で要求⇔テスト対応を検査する（EF フロー）
#   3. テストコマンドが記録されていて、前回の成功実行以降にコード変更があれば
#      テストスイートを実行する
# いずれかに失敗があれば exit 2 でブロックし、理由を stderr で Claude に返す
#（＝テストが失敗したまま・トレースが破綻したまま作業を終えられない、を機械的に強制）。
#
# 素通り条件（exit 0）:
#   - specs/ も examples.md も無い（SDD/EF フロー外）
#   - stop_hook_active（既にこのフックで継続中 -> 無限ブロック防止）
#
# テスト実行の条件化:
#   git が使えるなら HEAD と status（.md のみの変更行は除外）から SHA256 の状態値を作り、
#   .claude/.last-test-state と一致すればテストをスキップ。テスト成功時のみ状態値を更新。
#   git が無い/失敗する場合は常に実行（安全側）。trace-lint 系は毎回実行（軽いため）。
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

$specsDir = Join-Path $root 'specs'
$examplesFile = Join-Path $root 'examples.md'
$hasSpecs = Test-Path -LiteralPath $specsDir
$hasExamples = Test-Path -LiteralPath $examplesFile

# SDD/EF どちらのフロー外なら素通り
if (-not $hasSpecs -and -not $hasExamples) { exit 0 }

$problems = @()

# 1. SDD トレーサビリティ検査（specs/ があるとき）
if ($hasSpecs) {
    $traceScript = Join-Path $root '.claude/hooks/trace-lint.ps1'
    if (Test-Path -LiteralPath $traceScript) {
        $traceOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $traceScript -ProjectRoot $root
        if ($LASTEXITCODE -ne 0) {
            $problems += ("トレーサビリティ検査に失敗しました:`n" + (($traceOut) -join "`n"))
        }
    }
}

# 2. EF 要求⇔テスト対応検査（examples.md があるとき）
if ($hasExamples) {
    $efScript = Join-Path $root '.claude/hooks/ef-trace-lint.ps1'
    if (Test-Path -LiteralPath $efScript) {
        $efOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $efScript -ProjectRoot $root
        if ($LASTEXITCODE -ne 0) {
            $problems += ("要求⇔テスト対応の検査に失敗しました:`n" + (($efOut) -join "`n"))
        }
    }
}

# 3. テストスイート実行（記録されたコマンドがあり、コード変更があるとき）
# テストコマンドの探索: .specify/memory を優先し、無ければ .claude/memory
$testCmd = ""
$specifyCmdFile = Join-Path $root '.specify/memory/test-command.txt'
$claudeCmdFile = Join-Path $root '.claude/memory/test-command.txt'
if (Test-Path -LiteralPath $specifyCmdFile) {
    $testCmd = (Get-Content -Raw -LiteralPath $specifyCmdFile).Trim()
}
elseif (Test-Path -LiteralPath $claudeCmdFile) {
    $testCmd = (Get-Content -Raw -LiteralPath $claudeCmdFile).Trim()
}

if ($testCmd) {
    # 現在のコード状態値を算出（git が使えるとき。.md のみの変更は除外）
    $stateValue = $null
    $stateFile = Join-Path $root '.claude/.last-test-state'
    try {
        Push-Location $root
        try {
            $head = (& git rev-parse HEAD 2>$null)
            if ($LASTEXITCODE -eq 0 -and $head) {
                $porcelain = @(& git status --porcelain 2>$null)
                # .md のみの変更行を除外（末尾が .md のパスの行）
                $codeChanges = $porcelain | Where-Object { $_ -notmatch '\.md"?\s*$' }
                $combined = ($head + "`n" + (($codeChanges) -join "`n"))
                $sha = [System.Security.Cryptography.SHA256]::Create()
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
                $hashBytes = $sha.ComputeHash($bytes)
                $stateValue = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '')
            }
        }
        finally { Pop-Location }
    }
    catch { $stateValue = $null }

    $skipTests = $false
    if ($stateValue) {
        if (Test-Path -LiteralPath $stateFile) {
            $saved = (Get-Content -Raw -LiteralPath $stateFile -ErrorAction SilentlyContinue)
            if ($saved) { $saved = $saved.Trim() }
            if ($saved -eq $stateValue) { $skipTests = $true }
        }
    }

    if (-not $skipTests) {
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
        elseif ($stateValue) {
            # 成功したときだけ状態値を更新
            $claudeDir = Join-Path $root '.claude'
            if (-not (Test-Path -LiteralPath $claudeDir)) {
                New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
            }
            Set-Content -LiteralPath $stateFile -Value $stateValue -NoNewline -Encoding ASCII
        }
    }
}

if ($problems.Count -gt 0) {
    $message = "作業を終了できません。次の問題を解決してから停止してください:`n`n" + ($problems -join "`n`n")
    [Console]::Error.WriteLine($message)
    exit 2
}

exit 0
