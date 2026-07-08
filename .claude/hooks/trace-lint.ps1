#requires -Version 5.1
# trace-lint.ps1 — トレーサビリティ検査（G3 の機械化可能な 2 項）
#
# specs/**/spec.md から要件 ID を抽出し、テストファイルの `SPEC: <ID>` 注釈と相互参照して
# 次の 2 異常を報告する:
#   - 仕様に存在しない ID を参照するテスト   → テストの捏造
#   - どのテストからも参照されない要件 ID     → 検証漏れ
#
# 終了コード: 0 = 正常 or 検査対象外（素通り） / 1 = 異常あり
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

$specsDir = Join-Path $ProjectRoot 'specs'
if (-not (Test-Path -LiteralPath $specsDir)) {
    # SDD フロー外 -> 静かに素通り
    exit 0
}

# 要件 ID の形式（Spec-Kit）。UTF-8 等の誤検出を避けるため既知の接頭辞に限定する。
$idPattern = '\b(?:FR|NFR|SC|EC|US|AC|IR|KR|BR|DR|TR|PR)-\d+\b'
# テストファイル名の一般的な規約（test_x / x_test / x.test / x.spec など）。
$testNamePattern = '(?i)(^test|test$|_test|test_|\.test\b|\.spec\b|^spec|spec$|_spec|spec_)'
# 走査から除外するディレクトリ。
$excludeDirs = '(?i)[\\/](\.git|\.svn|\.hg|node_modules|target|dist|build|out|bin|obj|\.venv|venv|env|__pycache__|\.specify|\.claude|specs)[\\/]'

# 1. 仕様から要件 ID を収集
$specFiles = Get-ChildItem -LiteralPath $specsDir -Recurse -File -Filter 'spec.md' -ErrorAction SilentlyContinue
$specIds = New-Object System.Collections.Generic.HashSet[string]
foreach ($f in $specFiles) {
    $text = Get-Content -Raw -LiteralPath $f.FullName
    if ($null -eq $text) { continue }
    foreach ($m in [regex]::Matches($text, $idPattern)) {
        [void]$specIds.Add($m.Value)
    }
}

if ($specIds.Count -eq 0) {
    Write-Output "trace-lint: specs/ に要件 ID が見つかりませんでした。検査をスキップします。"
    exit 0
}

# 2. テストファイルを収集
$testFiles = Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Extension -ne '.md' -and
    $_.FullName -notmatch $excludeDirs -and
    $_.BaseName -match $testNamePattern
}

if (-not $testFiles -or @($testFiles).Count -eq 0) {
    # まだテストが無い（実装前フェーズ）-> 検証漏れ判定は時期尚早。素通り。
    Write-Output "trace-lint: テストファイルがまだありません。トレース検査をスキップします。"
    exit 0
}
$testFiles = @($testFiles)

# 3. テストから SPEC 注釈の ID を収集
$referenced = New-Object System.Collections.Generic.HashSet[string]
$fabrications = @()   # 仕様に無い ID を参照するテスト
foreach ($tf in $testFiles) {
    $text = Get-Content -Raw -LiteralPath $tf.FullName
    if ($null -eq $text) { continue }
    foreach ($sm in [regex]::Matches($text, 'SPEC:\s*([^\r\n]*)')) {
        $tail = $sm.Groups[1].Value
        foreach ($idm in [regex]::Matches($tail, $idPattern)) {
            $id = $idm.Value
            [void]$referenced.Add($id)
            if (-not $specIds.Contains($id)) {
                $rel = $tf.FullName.Substring($ProjectRoot.Length).TrimStart('\', '/')
                $fabrications += [pscustomobject]@{ Test = $rel; Id = $id }
            }
        }
    }
}

# 4. 検証漏れ = どのテストからも参照されない要件 ID
$gaps = @()
foreach ($id in $specIds) {
    if (-not $referenced.Contains($id)) { $gaps += $id }
}

# 5. 報告
Write-Output "=== trace-lint: トレーサビリティ検査 ==="
Write-Output ("仕様の要件 ID: {0} 件 / テストファイル: {1} 件" -f $specIds.Count, $testFiles.Count)

$hasError = $false

if ($fabrications.Count -gt 0) {
    $hasError = $true
    Write-Output ""
    Write-Output "[テストの捏造] 仕様に存在しない ID を参照するテスト:"
    foreach ($fab in ($fabrications | Sort-Object Test, Id -Unique)) {
        Write-Output ("  - {0} が未定義の {1} を参照" -f $fab.Test, $fab.Id)
    }
}

if ($gaps.Count -gt 0) {
    $hasError = $true
    Write-Output ""
    Write-Output "[検証漏れ] どのテストからも参照されない要件 ID:"
    foreach ($id in ($gaps | Sort-Object)) {
        Write-Output ("  - {0}" -f $id)
    }
}

if ($hasError) {
    Write-Output ""
    Write-Output "対処: 捏造テストは削除するか仕様の欠落として差し戻し、検証漏れの要件にはテストを追加してください。"
    exit 1
}

Write-Output "OK: すべての要件がテストから参照され、捏造テストはありません。"
exit 0
