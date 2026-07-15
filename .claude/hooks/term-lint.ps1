#requires -Version 5.1
# term-lint.ps1 — PostToolUse (Write|Edit) フック（曖昧語の取り締まり）
#
# Write/Edit が .md ファイルに触れたとき、term-dict.txt の正規表現に該当する
# 曖昧語（適切に・柔軟に・軽量な 等）を検出し、additionalContext として警告を返す。
# ブロックはしない（警告のみ）。常に exit 0。
#
# 素通り条件（exit 0・出力なし）:
#   - 対象が .md でない
#   - 対象が req-trace-matrix.md（自動生成物）
#   - 対象が .claude/ 配下
#   - 違反が無い
#
# コードフェンス（``` で囲まれた範囲）内はスキップする。
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

$file = $null
if ($data -and $data.tool_input) { $file = $data.tool_input.file_path }
if (-not $file) { exit 0 }

# .md 以外は素通り
$ext = [System.IO.Path]::GetExtension($file)
if ($ext -ne '.md') { exit 0 }

# 自動生成物と .claude/ 配下は素通り
$leaf = [System.IO.Path]::GetFileName($file)
if ($leaf -ieq 'req-trace-matrix.md') { exit 0 }
if ($file -match '(?i)[\\/]\.claude[\\/]') { exit 0 }

if (-not (Test-Path -LiteralPath $file)) { exit 0 }

# 辞書読み込み
$dictPath = Join-Path $root '.claude/hooks/term-dict.txt'
if (-not (Test-Path -LiteralPath $dictPath)) {
    # スクリプトと同じディレクトリからも探す
    $dictPath = Join-Path $PSScriptRoot 'term-dict.txt'
}
if (-not (Test-Path -LiteralPath $dictPath)) { exit 0 }

$rules = @()
foreach ($dline in (Get-Content -LiteralPath $dictPath -Encoding UTF8)) {
    if (-not $dline) { continue }
    $trimmed = $dline.TrimStart()
    if ($trimmed.StartsWith('#')) { continue }
    if ($dline.Trim() -eq '') { continue }
    $parts = $dline -split "`t", 2
    if ($parts.Count -lt 2) { continue }
    $pattern = $parts[0].Trim()
    $message = $parts[1].Trim()
    if (-not $pattern) { continue }
    $rules += [pscustomobject]@{ Pattern = $pattern; Message = $message }
}
if ($rules.Count -eq 0) { exit 0 }

# 対象ファイルを行単位で検査（コードフェンス内はスキップ）
$lines = Get-Content -LiteralPath $file -Encoding UTF8 -ErrorAction SilentlyContinue
if ($null -eq $lines) { exit 0 }

$violations = @()
$inFence = $false
$lineNo = 0
foreach ($line in $lines) {
    $lineNo++
    if ($line -match '^\s*```') {
        $inFence = -not $inFence
        continue
    }
    if ($inFence) { continue }
    foreach ($rule in $rules) {
        $mm = [regex]::Match($line, $rule.Pattern)
        if ($mm.Success) {
            $violations += [pscustomobject]@{
                Line    = $lineNo
                Term    = $mm.Value
                Message = $rule.Message
            }
        }
    }
}

if ($violations.Count -eq 0) { exit 0 }

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("警告: '$leaf' に曖昧語が見つかりました。具体的な条件・数値・責務・固有名に書き換えてください（term-lint）。")
foreach ($v in $violations) {
    [void]$sb.AppendLine(("  - {0} 行目「{1}」: {2}" -f $v.Line, $v.Term, $v.Message))
}

$out = @{
    hookSpecificOutput = @{
        hookEventName     = 'PostToolUse'
        additionalContext = $sb.ToString().TrimEnd()
    }
}
$out | ConvertTo-Json -Compress -Depth 5
exit 0
