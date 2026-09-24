# Runs claudecost.ps1 on a small made-up log folder and checks the numbers.
# Works in Windows PowerShell 5.1 and PowerShell 7+.   Usage: ./tests/run-tests.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$env:NO_COLOR = '1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('claudecost-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script = Join-Path $root 'claudecost.ps1'
$dir = Join-Path $root 'tests/fixtures/projects'
$fail = $false

function Normalize([string]$text) {
  # Ignore leading, trailing and repeated spaces
  @($text -split "`r?`n" | ForEach-Object { ($_.Trim() -replace ' +', ' ') })
}

# 1. PowerShell-style options
$html = Join-Path $tmp 'report.html'
$out = & $script -Offline -Dir $dir -Since 2026-09-01 -Until 2026-09-30 -Html $html *>&1 | Out-String
$norm = Normalize $out
foreach ($line in (Get-Content -LiteralPath (Join-Path $root 'tests/expected.txt') -Encoding UTF8)) {
  if ($line.Trim() -eq '') { continue }
  if ($norm -cnotcontains $line) { Write-Host "MISSING in terminal output: $line"; $fail = $true }
}
if (-not (Test-Path -LiteralPath $html)) { Write-Host 'MISSING: HTML report was not written'; $fail = $true }
else {
  $h = [IO.File]::ReadAllText($html, [Text.Encoding]::UTF8)
  foreach ($line in (Get-Content -LiteralPath (Join-Path $root 'tests/expected-html.txt') -Encoding UTF8)) {
    if ($line.Trim() -eq '') { continue }
    if (-not $h.Contains($line)) { Write-Host "MISSING in HTML report: $line"; $fail = $true }
  }
}

# 2. The bash-style options of claudecost.sh give the same answer
$out2 = & $script --offline --dir $dir --since 2026-09-01 --until 2026-09-30 *>&1 | Out-String
if ((Normalize $out2) -cnotcontains (Get-Content -LiteralPath (Join-Path $root 'tests/expected.txt') -Encoding UTF8 | Select-Object -First 1)) {
  Write-Host 'MISSING: bash-style options did not give the same total'; $fail = $true
}

# 3. A bad option stops with an error
$null = & $script -Offline -Dir $dir -Days abc *>&1
if ($LASTEXITCODE -ne 1) { Write-Host "MISSING: -Days abc should exit with 1, got $LASTEXITCODE"; $fail = $true }
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host 'FAILED'; Write-Host $out; exit 1 }
Write-Host 'OK: claudecost.ps1'
exit 0   # the bad-option check above leaves an exit code of 1 behind
