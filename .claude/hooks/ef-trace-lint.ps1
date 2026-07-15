#requires -Version 5.1
# ef-trace-lint.ps1 — Example-First のトレーサビリティ検査
#
# ルート直下の examples.md から要求 ID（REQ-01 等）を抽出し、
# テストファイルの REQ-xx 注釈と相互参照して次の 2 異常を報告する:
#   - examples.md に存在しない ID を参照するテスト → 捏造参照
#   - どのテストからも参照されない要求 ID          → 検証漏れ
# あわせて要求⇔テスト対応表 req-trace-matrix.md を生成する。
#
# 終了コード: 0 = 正常 or 検査対象外（素通り） / 1 = 異常あり
#
# 素通り条件（exit 0・出力なし）:
#   - ルート直下に examples.md が無い（EF フロー外）
#   - examples.md に要求 ID が 0 件
#
# Windows PowerShell 5.1 互換（&& / 三項演算子 / null 合体演算子は使わない）。

[CmdletBinding()]
param(
    [string]$ProjectRoot = ""
)

$ErrorActionPreference = 'Stop'

if (-not $ProjectRoot) {
    if ($env:CLAUDE_PROJECT_DIR) { $ProjectRoot = $env:CLAUDE_PROJECT_DIR }
    else { $ProjectRoot = (Get-Location).Path }
}

$examplesFile = Join-Path $ProjectRoot 'examples.md'
if (-not (Test-Path -LiteralPath $examplesFile)) {
    # EF フロー外 -> 静かに素通り
    exit 0
}

# 要求 ID の形式。初出行のテキストも保持する。
$idPattern = 'REQ-\d{2,}'
# テストファイル名の一般的な規約（test_x / x_test / x.test / x.spec など）。MATLAB 含む。
$testNamePattern = '(?i)(^test|test$|_test|test_|\.test\.|\.spec\.|^spec|spec$|_spec)'
# 走査から除外するディレクトリ。
$excludeDirs = '(?i)[\\/](node_modules|\.git|\.specify|\.claude|target|dist|build|vendor)[\\/]'

# 1. examples.md から要求 ID と初出行テキストを収集
$reqDefs = [ordered]@{}   # ID -> 初出行テキスト
$exampleLines = Get-Content -LiteralPath $examplesFile -Encoding UTF8 -ErrorAction SilentlyContinue
foreach ($line in $exampleLines) {
    foreach ($m in [regex]::Matches($line, $idPattern)) {
        $id = $m.Value
        if (-not $reqDefs.Contains($id)) {
            $reqDefs[$id] = $line.Trim()
        }
    }
}

if ($reqDefs.Count -eq 0) {
    # 要求 ID の定義が無い -> 素通り
    exit 0
}

# 2. テストファイルを収集
$testFiles = Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Extension -ne '.md' -and
    $_.FullName -notmatch $excludeDirs -and
    $_.BaseName -match $testNamePattern
}
$testFiles = @($testFiles)

# 3. テストから REQ 参照を収集
$referencedBy = @{}       # ID -> 参照するテストの相対パス配列
$fabrications = @()       # examples.md に無い ID を参照するテスト
foreach ($tf in $testFiles) {
    $text = Get-Content -Raw -LiteralPath $tf.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($null -eq $text) { continue }
    $rel = $tf.FullName.Substring($ProjectRoot.Length).TrimStart('\', '/')
    foreach ($idm in [regex]::Matches($text, $idPattern)) {
        $id = $idm.Value
        if ($reqDefs.Contains($id)) {
            if (-not $referencedBy.ContainsKey($id)) { $referencedBy[$id] = @() }
            if ($referencedBy[$id] -notcontains $rel) { $referencedBy[$id] += $rel }
        }
        else {
            $fabrications += [pscustomobject]@{ Test = $rel; Id = $id }
        }
    }
}

# 4. 検証漏れ = どのテストからも参照されない要求 ID
$gaps = @()
foreach ($id in $reqDefs.Keys) {
    if (-not $referencedBy.ContainsKey($id)) { $gaps += $id }
}

# 5. 要求⇔テスト対応表を生成
$matrixPath = Join-Path $ProjectRoot 'req-trace-matrix.md'
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# req-trace-matrix.md — 要求⇔テスト対応表')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('| 要求 | 定義行テキスト | 検証するテスト | 状態 |')
[void]$sb.AppendLine('|------|----------------|----------------|------|')
foreach ($id in $reqDefs.Keys) {
    $defText = $reqDefs[$id] -replace '\|', '\|'
    if ($referencedBy.ContainsKey($id)) {
        $tests = ($referencedBy[$id] | Sort-Object) -join '<br>'
        $state = 'OK'
    }
    else {
        $tests = '（なし）'
        $state = '検証漏れ'
    }
    [void]$sb.AppendLine(("| {0} | {1} | {2} | {3} |" -f $id, $defText, $tests, $state))
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($matrixPath, $sb.ToString(), $utf8)

# 6. 報告
$hasError = $false

if ($fabrications.Count -gt 0) {
    $hasError = $true
    Write-Output "[捏造参照] examples.md に存在しない要求 ID を参照するテスト:"
    foreach ($fab in ($fabrications | Sort-Object Test, Id -Unique)) {
        Write-Output ("  - {0} が未定義の {1} を参照" -f $fab.Test, $fab.Id)
    }
}

if ($gaps.Count -gt 0) {
    $hasError = $true
    Write-Output "[検証漏れ] どのテストからも参照されない要求 ID:"
    foreach ($id in ($gaps | Sort-Object)) {
        Write-Output ("  - {0}: {1}" -f $id, $reqDefs[$id])
    }
}

if ($hasError) {
    Write-Output ""
    Write-Output "対処: 捏造参照は注釈を修正するか examples.md の欠落として差し戻し、検証漏れの要求にはテストを追加してください。対応表: req-trace-matrix.md"
    exit 1
}

Write-Output ("ef-trace-lint OK: 要求 {0} 件すべてがテストから参照され、捏造参照はありません。対応表: req-trace-matrix.md" -f $reqDefs.Count)
exit 0
