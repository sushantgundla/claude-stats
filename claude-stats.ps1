#requires -Version 5.1
<#
.SYNOPSIS
  claude-stats - Claude Code usage stats (PowerShell port of claude-stats.sh)

.DESCRIPTION
  A zero-dependency PowerShell alternative to `npx ccusage`.
  Reads JSONL session logs from ~/.claude/projects/ and displays:
    - Total tokens, estimated API cost, active days, cache hit rate
    - Hourly/daily/weekly/monthly cost chart (text bar chart)
    - Per-model table and cost split by token type (cache read/write, input, output)
    - Side-by-side comparison of quota weeks (-Reset) or any time range
    - Top tools, MCP servers, skills, slash commands and subagents
    - Optional self-contained HTML report (-Html)

  Works on Windows PowerShell 5.1 and PowerShell 7+ (Windows, macOS, Linux).
  The bash-style options of claude-stats.sh (--days 7, --reset "wed 11:30", ...) work too.

  Pricing: fetches latest from LiteLLM on every run (falls back to hardcoded)
  Dedup strategy: API message id; the largest count per field wins, because
    Claude Code logs one line per streamed content block and early lines carry
    partial output_tokens. Tool calls are deduplicated by tool_use id and slash
    commands by message uuid, since resumed sessions copy earlier lines.
  Dates: timestamps are UTC in the logs and are bucketed by local time.
  Cache writes: 1-hour writes (Claude Code's default) are priced at the 1-hour rate.

.EXAMPLE
  .\claude-stats.ps1                                        # all history
.EXAMPLE
  .\claude-stats.ps1 -Days 7                                # last 7 days
.EXAMPLE
  .\claude-stats.ps1 -Since "2026-09-16 11:30" -Until "2026-09-23 11:30"
.EXAMPLE
  .\claude-stats.ps1 -Reset "wed 11:30" -Weeks 4 -Current   # compare quota weeks
.EXAMPLE
  .\claude-stats.ps1 -Reset "wed 11:30" -Html report.html
.EXAMPLE
  .\claude-stats.ps1 -Freq monthly -Project my-app -Offline
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$Days,
  [string]$Since,
  [string]$Until,
  [string]$Month,
  [string]$Compare,
  [string]$Last,
  [switch]$Current,
  [string]$Reset,
  [string]$Weeks,
  [string]$Html,
  [string]$Top,
  [string]$Freq,
  [string]$Project,
  [string]$Dir,
  [switch]$Offline,
  [switch]$Help,
  [Parameter(ValueFromRemainingArguments = $true)] [string[]]$BashArgs
)

$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture
$epoch0 = [datetime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
$LITELLM_URL = 'https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json'

class URec { [long]$Ep; [int]$P; [string]$Date; [string]$Model; [string]$Sid; [int]$Side; [string]$Cwd
             [double]$In; [double]$Out; [double]$Cc; [double]$Cr; [double]$C1h }
class TRec { [long]$Ep; [int]$P; [string]$Cat; [string]$Name }
class CRec { [long]$Ep; [int]$P; [string]$Name }

function Show-Usage {
  Write-Host @'
Usage: claude-stats.ps1 [options]        (bash-style --options work too, e.g. --days 7)

One time range (default is all history):
  -Days N               Last N days
  -Since WHEN           Start, local time: YYYY-MM-DD or "YYYY-MM-DD HH:MM"
  -Until WHEN           End, local time: YYYY-MM-DD (inclusive) or "YYYY-MM-DD HH:MM" (exclusive)
  -Month YYYY-MM        One calendar month

Or compare up to 5 periods side by side:
  -Compare UNIT         day, week, month or year (complete periods, newest last)
  -Last N               How many complete periods (default 2, at most 5)
  -Current              Also show the period in progress (counts toward the 5)
  -Reset "DAY HH:MM"    Weekly boundary, e.g. your subscription reset "wed 23:30".
                        Implies -Compare week. Weeks otherwise start Monday 00:00.
  -Weeks N              Same as -Compare week -Last N

Output:
  -Html FILE            Also write a self-contained HTML report to FILE
  -Top N                Rows in the tools/MCP/skills/commands lists (default 10)
  -Freq FREQ            Chart step: auto (default), hourly, daily, weekly, monthly.
                        Auto is one level below the comparison: year→month,
                        month→week, week→day, day→hour.

Other:
  -Project PATTERN      Filter by project folder name (substring match)
  -Dir PATH             Custom log directory (default: ~/.claude/projects)
  -Offline              Skip LiteLLM fetch, use hardcoded pricing
'@
}

function Fail([string]$msg) { [Console]::Error.WriteLine("Error: $msg"); exit 1 }

# --- Options: PowerShell parameters, plus the bash-style ones of claude-stats.sh ---
$DaysV = $Days; $SinceV = $Since; $UntilV = $Until; $MonthV = $Month; $ResetV = $Reset
$CompareV = $Compare; $HtmlV = $Html; $ProjectV = $Project; $OfflineV = [bool]$Offline; $CurrentV = [bool]$Current
$FreqV = if ($Freq) { $Freq } else { 'auto' }
$TopV = if ($Top) { $Top } else { '10' }
$LastV = '2'; $LastSet = $false; $WeeksSet = $false
if ($PSBoundParameters.ContainsKey('Last')) { $LastV = $Last; $LastSet = $true }
if ($PSBoundParameters.ContainsKey('Weeks')) { $LastV = $Weeks; $LastSet = $true; $WeeksSet = $true }
$CLAUDE_DIR = if ($Dir) { $Dir } elseif ($env:CLAUDE_DIR) { $env:CLAUDE_DIR } else { Join-Path $HOME '.claude/projects' }
if ($Help) { Show-Usage; exit 0 }

$ba = @($BashArgs | Where-Object { $null -ne $_ })
for ($i = 0; $i -lt $ba.Count; $i++) {
  $a = $ba[$i]
  if (@('--days', '--month', '--since', '--until', '--reset', '--compare', '--last', '--weeks', '--html',
        '--top', '--project', '--dir', '--freq') -ccontains $a) {
    if ($i + 1 -ge $ba.Count) { Fail "$a needs a value" }
    $i++
    $val = $ba[$i]
    switch -CaseSensitive ($a) {
      '--days'    { $DaysV = $val }
      '--month'   { $MonthV = $val }
      '--since'   { $SinceV = $val }
      '--until'   { $UntilV = $val }
      '--reset'   { $ResetV = $val }
      '--compare' { $CompareV = $val }
      '--last'    { $LastV = $val; $LastSet = $true }
      '--weeks'   { $LastV = $val; $LastSet = $true; $WeeksSet = $true }
      '--html'    { $HtmlV = $val }
      '--top'     { $TopV = $val }
      '--project' { $ProjectV = $val }
      '--dir'     { $CLAUDE_DIR = $val }
      '--freq'    { $FreqV = $val }
    }
  }
  elseif ($a -ceq '--current') { $CurrentV = $true }
  elseif ($a -ceq '--offline') { $OfflineV = $true }
  elseif ($a -ceq '--help' -or $a -ceq '-h') { Show-Usage; exit 0 }
  else { Write-Host "Unknown option: $a"; Show-Usage; exit 1 }
}

if (-not (Test-Path -LiteralPath $CLAUDE_DIR -PathType Container)) {
  Write-Host "Error: Claude logs directory not found: $CLAUDE_DIR"
  Write-Host "Set CLAUDE_DIR or use -Dir to point to your logs."
  exit 1
}
if ($DaysV -and $DaysV -notmatch '^\d+$') { Fail "-Days needs a whole number" }
if ($TopV -notmatch '^\d+$') { Fail "-Top needs a whole number" }
$top_n = [int]$TopV

# --- Colors: off when NO_COLOR is set or output is redirected; FORCE_COLOR=1 keeps them ---
$NOCOLOR = [bool]$env:NO_COLOR -or [Console]::IsOutputRedirected
if ($env:FORCE_COLOR -and $env:FORCE_COLOR -ne '0') { $NOCOLOR = $false }
if (-not [Console]::IsOutputRedirected) {
  # The report uses box and arrow characters: print them as UTF-8 (Windows PowerShell defaults to the old code page)
  try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
  # Windows consoles only understand colour codes once "virtual terminal" mode is on; without it they print as text
  if (-not $NOCOLOR -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and -not $env:WT_SESSION) {
    try {
      Add-Type -Namespace ClaudeStats -Name Con -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n); [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out int m); [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, int m);'
      $vtH = [ClaudeStats.Con]::GetStdHandle(-11); $vtM = 0
      if (-not ([ClaudeStats.Con]::GetConsoleMode($vtH, [ref]$vtM) -and [ClaudeStats.Con]::SetConsoleMode($vtH, ($vtM -bor 4)))) { $NOCOLOR = $true }
    }
    catch { $NOCOLOR = $true }
  }
}
$ESC = [string][char]27
function tc([string]$code) { if ($NOCOLOR) { '' } else { $ESC + '[' + $code + 'm' } }
$DIM = tc '2'; $YELLOW = tc '33'; $RESET = tc '0'

# --- Date helpers (local time) ---
# "YYYY-MM-DD HH:MM" (local) -> epoch seconds
function To-Epoch([string]$s) {
  $dt = [datetime]::ParseExact($s, 'yyyy-MM-dd H:mm', $inv)
  [DateTimeOffset]::new([datetime]::SpecifyKind($dt, [DateTimeKind]::Local)).ToUnixTimeSeconds()
}
# epoch seconds -> local time in a .NET format
function Fmt-Epoch([long]$e, [string]$fmt) { [DateTimeOffset]::FromUnixTimeSeconds($e).ToLocalTime().ToString($fmt, $inv) }
function Add-Days([string]$d, [int]$n) { [datetime]::ParseExact($d, 'yyyy-MM-dd', $inv).AddDays($n).ToString('yyyy-MM-dd', $inv) }
function Add-Months([string]$d, [int]$n) { [datetime]::ParseExact($d, 'yyyy-MM-dd', $inv).AddMonths($n).ToString('yyyy-MM-dd', $inv) }

# "YYYY-MM-DD" or "YYYY-MM-DD HH:MM" -> epoch; $end makes a bare date mean "end of that day"
function Parse-When([string]$s, [switch]$End) {
  try {
    if ($s -match '^\d{4}-\d{2}-\d{2}$') {
      if ($End) { return To-Epoch ((Add-Days $s 1) + ' 00:00') }
      return To-Epoch ($s + ' 00:00')
    }
    if ($s -match '^\d{4}-\d{2}-\d{2} \d{1,2}:\d{2}$') { return To-Epoch $s }
  } catch { }
  Fail "bad date '$s' (use YYYY-MM-DD or `"YYYY-MM-DD HH:MM`")"
}

# --- Fetch LiteLLM pricing (default behavior) ---
# Rows of model, input, output, cache_write_5m, cache_read, cache_write_1h (per 1M tokens)
$PriceRows = [Collections.Generic.List[object]]::new()
if (-not $OfflineV) {
  Write-Host ($DIM + 'Fetching latest pricing from LiteLLM...' + $RESET)
  try {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $resp = Invoke-WebRequest -Uri $LITELLM_URL -UseBasicParsing -TimeoutSec 30
    $json = $resp.Content
    if ($json -is [byte[]]) { $json = [Text.Encoding]::UTF8.GetString($json) }
    # The file is pretty-printed: models are the keys one level deep, prices the numbers two levels deep
    $depth = 0; $model = $null; $fields = @{}
    $reJsonStr = [regex]::new('"(?:[^"\\]|\\.)*"')
    $flush = {
      if ($model -and $model -cmatch '^(anthropic/)?claude-') {
        $inp = [double]$fields['input_cost_per_token']; $out = [double]$fields['output_cost_per_token']
        $cw = [double]$fields['cache_creation_input_token_cost']; $cr = [double]$fields['cache_read_input_token_cost']
        $cw1h = [double]$fields['cache_creation_input_token_cost_above_1hr']
        if ($inp -gt 0 -or $out -gt 0) {
          if ($cw1h -eq 0) { $cw1h = $inp * 2 }
          $PriceRows.Add(@($model, ($inp * 1e6), ($out * 1e6), ($cw * 1e6), ($cr * 1e6), ($cw1h * 1e6)))
        }
      }
    }
    foreach ($raw in ($json -split "`n")) {
      $line = $raw.Trim()
      if ($depth -eq 1 -and $line -match '^"([a-zA-Z][^"]*)"\s*:\s*\{') {
        $next = $Matches[1]   # read before $flush, whose -cmatch resets $Matches
        . $flush
        $model = $next; $fields = @{}
      }
      elseif ($depth -eq 2 -and $model -and $line -match '^"([^"]+)"\s*:\s*([-+0-9.eE]+)\s*,?$') {
        $num = 0.0
        if ([double]::TryParse($Matches[2], [Globalization.NumberStyles]::Float, $inv, [ref]$num)) { $fields[$Matches[1]] = $num }
      }
      # count braces outside string values (some notes contain {placeholders})
      $bare = $reJsonStr.Replace($line, '""')
      $depth += ($bare.Split('{').Count - 1) - ($bare.Split('}').Count - 1)
    }
    . $flush
    Write-Host ($DIM + "Loaded pricing for $($PriceRows.Count) Claude models" + $RESET)
  }
  catch {
    Write-Host ($YELLOW + 'Warning: Could not fetch LiteLLM pricing, using hardcoded defaults' + $RESET)
  }
}

# --- Periods: one entry per column to report (1-based: index 0 is unused) ---
$ps = @([long]0); $pe = @([long]0); $plab = @(''); $plong = @('')
function Add-Period([long]$s, [long]$e, [string]$short, [string]$long) {
  $script:ps += $s; $script:pe += $e; $script:plab += $short; $script:plong += $long
}
$NOW = [DateTimeOffset]::Now.ToUnixTimeSeconds()
$LABEL_FMT = 'ddd MMM dd HH:mm'

$COMPARE = ''
if ($CompareV) {
  if (@('day', 'days', 'daily') -contains $CompareV) { $COMPARE = 'day' }
  elseif (@('week', 'weeks', 'weekly') -contains $CompareV) { $COMPARE = 'week' }
  elseif (@('month', 'months', 'monthly') -contains $CompareV) { $COMPARE = 'month' }
  elseif (@('year', 'years', 'yearly') -contains $CompareV) { $COMPARE = 'year' }
  else { Fail '-Compare takes day, week, month or year' }
}
if ($ResetV -or $WeeksSet) {
  if (-not $COMPARE) { $COMPARE = 'week' }
  if ($COMPARE -ne 'week') { Fail '-Reset and -Weeks only work with weekly comparisons' }
}
if (-not $COMPARE -and ($LastSet -or $CurrentV)) {
  Fail '-Last, -Weeks and -Current need -Compare or -Reset, e.g. -Reset "wed 11:30"'
}

$BUCKET = 'auto'
if ($COMPARE) {
  if ("$DaysV$SinceV$UntilV$MonthV") { Fail '-Compare/-Reset cannot be combined with -Days, -Since, -Until or -Month' }
  if ($LastV -notmatch '^[1-5]$') { Fail '-Last/-Weeks must be 1 to 5 (at most 5 periods are compared)' }
  $NLAST = [int]$LastV
  $TOTAL = $NLAST
  if ($CurrentV) { $TOTAL = $NLAST + 1 }
  if ($TOTAL -gt 5) { Fail "at most 5 periods can be compared; -Last $NLAST with -Current makes $TOTAL" }

  $TODAY = (Get-Date).ToString('yyyy-MM-dd', $inv)
  $B_TIME = '00:00'
  switch ($COMPARE) {
    'day'   { $BASE = $TODAY; $BUCKET = 'hour'; $CUR_LABEL = 'Today' }
    'month' { $BASE = (Get-Date).ToString('yyyy-MM', $inv) + '-01'; $BUCKET = 'week'; $CUR_LABEL = 'This month' }
    'year'  { $BASE = (Get-Date).ToString('yyyy', $inv) + '-01-01'; $BUCKET = 'month'; $CUR_LABEL = 'This year' }
    'week'  {
      $BUCKET = 'day'; $CUR_LABEL = 'This week'
      $R_DAY = 'mon'; $R_TIME = '00:00'
      if ($ResetV) {
        $parts = @($ResetV.Trim() -split '\s+', 2)
        $R_DAY = $parts[0].ToLowerInvariant()
        if ($R_DAY.Length -gt 3) { $R_DAY = $R_DAY.Substring(0, 3) }
        $R_TIME = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        if ($R_DAY -notmatch '^(mon|tue|wed|thu|fri|sat|sun)$' -or $R_TIME -notmatch '^\d{1,2}:\d{2}$') {
          Fail '-Reset needs a weekday and a time, e.g. -Reset "wed 11:30"'
        }
      }
      $B_TIME = $R_TIME
      # Most recent boundary at or before now
      $BASE = ''
      for ($k = 0; $k -le 7; $k++) {
        $d = Add-Days $TODAY (-$k)
        $e = To-Epoch "$d $R_TIME"
        $wd = (Fmt-Epoch $e 'ddd').ToLowerInvariant()
        if ($wd -eq $R_DAY -and $e -le $NOW) { $BASE = $d; break }
      }
    }
  }

  # Start date of the period k steps before the one in progress (k = 0 is current)
  function Period-Start([int]$k) {
    switch ($COMPARE) {
      'day'   { Add-Days $BASE (-$k) }
      'week'  { Add-Days $BASE (-7 * $k) }
      'month' { Add-Months $BASE (-$k) }
      'year'  { ([int]$BASE.Substring(0, 4) - $k).ToString($inv) + '-01-01' }
    }
  }
  function Short-Label([long]$s, [int]$idx) {
    switch ($COMPARE) {
      'day'   { Fmt-Epoch $s 'ddd MMM dd' }
      'week'  { "Week $idx" }
      'month' { Fmt-Epoch $s 'MMM yyyy' }
      'year'  { Fmt-Epoch $s 'yyyy' }
    }
  }
  function Long-Label([long]$s, [long]$e) {
    switch ($COMPARE) {
      'day'   { Fmt-Epoch $s 'ddd MMM dd yyyy' }
      'week'  { (Fmt-Epoch $s $LABEL_FMT) + ' → ' + (Fmt-Epoch $e $LABEL_FMT) }
      default { (Fmt-Epoch $s 'MMM dd yyyy') + ' → ' + (Fmt-Epoch $e 'MMM dd yyyy') }
    }
  }

  $idx = 0
  for ($k = $NLAST; $k -ge 1; $k--) {
    $s = To-Epoch ((Period-Start $k) + " $B_TIME")
    $e = To-Epoch ((Period-Start ($k - 1)) + " $B_TIME")
    $idx++
    Add-Period $s $e (Short-Label $s $idx) (Long-Label $s $e)
  }
  if ($CurrentV) {
    $s = To-Epoch ((Period-Start 0) + " $B_TIME")
    if ($COMPARE -eq 'day') { $CUR_LONG = (Fmt-Epoch $s 'ddd MMM dd') + ' (in progress)' }
    else { $CUR_LONG = (Fmt-Epoch $s $LABEL_FMT) + ' → now (in progress)' }
    Add-Period $s ($NOW + 1) $CUR_LABEL $CUR_LONG
  }
}
else {
  $START = [long]0
  $END = $NOW + 86400
  if ($DaysV) { $START = To-Epoch ((Add-Days (Get-Date).ToString('yyyy-MM-dd', $inv) (-[int]$DaysV)) + ' 00:00') }
  if ($MonthV) {
    if ($MonthV -notmatch '^\d{4}-\d{2}$') { Fail '-Month needs YYYY-MM' }
    $START = Parse-When "$MonthV-01"
    try { $END = To-Epoch ((Add-Months "$MonthV-01" 1) + ' 00:00') } catch { Fail "bad month '$MonthV'" }
  }
  if ($SinceV) { $START = Parse-When $SinceV }
  if ($UntilV) { $END = Parse-When $UntilV -End }
  if ($START -gt 0) {
    if ($UntilV -or $MonthV) { $LONG = (Fmt-Epoch $START $LABEL_FMT) + ' → ' + (Fmt-Epoch $END $LABEL_FMT) }
    else { $LONG = (Fmt-Epoch $START $LABEL_FMT) + ' → now' }
  }
  else { $LONG = 'All history' }
  Add-Period $START $END 'Selected' $LONG
}
$nper = $ps.Count - 1

switch ($FreqV) {
  'auto' { }
  { $_ -in 'hourly', 'hour' } { $BUCKET = 'hour' }
  { $_ -in 'daily', 'day' } { $BUCKET = 'day' }
  { $_ -in 'weekly', 'week' } { $BUCKET = 'week' }
  { $_ -in 'monthly', 'month' } { $BUCKET = 'month' }
  default { Fail '-Freq takes auto, hourly, daily, weekly or monthly' }
}

# Local UTC offset in seconds, e.g. +05:30 -> 19800
$tzs = [long][TimeZoneInfo]::Local.GetUtcOffset([datetime]::Now).TotalSeconds

# --- Find JSONL files (including subagent sessions) ---
# Every file is read, even ones last written before the range: resumed sessions
# copy old messages into new files, and the earliest copy decides where a
# message is counted.
$files = @(Get-ChildItem -LiteralPath $CLAUDE_DIR -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)
if ($ProjectV) { $files = @($files | Where-Object { $_.FullName.IndexOf($ProjectV, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
if ($files.Count -eq 0) {
  Write-Host "No JSONL files found in $CLAUDE_DIR"
  exit 1
}
Write-Host ($DIM + "Scanning $($files.Count) session files..." + $RESET)
$GEN_TIME = (Get-Date).ToString("yyyy-MM-dd HH:mm 'UTC'zzz", $inv)

# ============================ SHARED HELPERS ============================
function NewMap { [hashtable]::new([StringComparer]::Ordinal) }
$dayStr = @{}
function DayStr([long]$dn) {
  $s = $dayStr[$dn]
  if ($null -eq $s) { $s = $epoch0.AddDays($dn).ToString('yyyy-MM-dd', $inv); $dayStr[$dn] = $s }
  $s
}
# epoch seconds -> local YYYY-MM-DD
function LocalDate([long]$ep) { DayStr ([long][math]::Floor(($ep + $tzs) / 86400)) }
function PeriodOf([long]$ep) {
  for ($q = 1; $q -le $nper; $q++) { if ($ep -ge $ps[$q] -and $ep -lt $pe[$q]) { return $q } }
  return 0
}

# First word of a shell command, as a name: skips VAR=value prefixes and a leading "cd dir" line or "cd dir &&"
function BashWord([string]$c) {
  $c = [regex]::Replace($c, '[A-Za-z_][A-Za-z0-9_]*=\$\(', ' ')   # D=$(find ...) runs find
  $c = $c.Replace('\n', ' ; ').Replace('\t', ' ')
  $c = [regex]::Replace($c, '&&|;', ' ; ')
  $t = [regex]::Split($c, '[ \t]+')
  $n = $t.Count; $i = 0
  while ($i -lt $n) {
    if ($t[$i] -eq '' -or $t[$i] -eq ';' -or $t[$i] -cmatch '^[A-Za-z_][A-Za-z0-9_]*=') { $i++; continue }
    if ($t[$i] -ceq 'cd') { $i++; while ($i -lt $n -and $t[$i] -ne ';') { $i++ }; continue }
    break
  }
  if ($i -ge $n) { return '' }
  $w = $t[$i] -replace '^.*[/\\]', ''
  $w -creplace '[^A-Za-z0-9_.+-]', ''
}

# "dir/file" from a full path (JSON-escaped Windows paths too)
function ShortPath([string]$f) {
  $a = $f.Replace('\\', '\') -split '[\\/]'
  if ($a.Count -ge 2) { return $a[$a.Count - 2] + '/' + $a[$a.Count - 1] }
  $f
}

# ============================ READ THE LOGS ============================
$UMap = NewMap; $TMap = NewMap; $CMap = NewMap
$raw_u = 0; $raw_t = 0; $raw_c = 0

function EmitT([string]$k, [int]$p, [string]$cat, [string]$name, [long]$ep) {
  if ($p -gt 0 -and ($cat -eq 'tool' -or $cat -eq 'mcp')) { $script:raw_t++ }
  $r = $TMap[$k]
  if ($null -eq $r) { $r = [TRec]::new(); $r.Ep = $ep; $r.P = $p; $r.Cat = $cat; $r.Name = $name; $TMap[$k] = $r }
  elseif ($ep -lt $r.Ep) { $r.Ep = $ep; $r.P = $p; $r.Cat = $cat; $r.Name = $name }
}

$reTs      = [regex]::new('"timestamp":"([^"]*)"', 'Compiled, RightToLeft')
$reIso     = [regex]::new('^\d{4}-\d{2}-\d{2}.\d{2}:\d{2}:\d{2}', 'Compiled')
$reUuid    = [regex]::new('"uuid":"([^"]*)"', 'Compiled, RightToLeft')
$reSid     = [regex]::new('"sessionId":"([^"]*)"', 'Compiled, RightToLeft')
$reCwd     = [regex]::new('"cwd":"([^"]*)"', 'Compiled, RightToLeft')
$reSide    = [regex]::new('"isSidechain":(true|false)', 'Compiled')
$reCmdTag  = [regex]::new('"content":"(<command-[^"]*)', 'Compiled')
$reCmdName = [regex]::new('<command-name>([^<]*)', 'Compiled')
$reCmdText = [regex]::new('"role":"user","content":"/([A-Za-z][A-Za-z0-9_:-]*)(?=[ ,"\\])', 'Compiled')
$reTool    = [regex]::new('"type":"tool_use","id":"([^"]*)","name":"([^"]*)"', 'Compiled')
$reSkill   = [regex]::new('"skill":"([^"]*)"', 'Compiled')
$reCommand = [regex]::new('"command":"((?:[^"\\]|\\.)*)', 'Compiled')
$reFile    = [regex]::new('"file_path":"([^"]*)', 'Compiled')
$reSubType = [regex]::new('"subagent_type":"([^"]*)"', 'Compiled')
$reModel   = [regex]::new('"model":"([^"]*)"(?:,"id":"([^"]*)")?', 'Compiled')
$reMsgId   = [regex]::new('"message":\{"id":"([^"]*)"', 'Compiled')
$reModelId = [regex]::new('"model":"[^"]*","id":"([^"]*)"', 'Compiled')
$reIn      = [regex]::new('"input_tokens":([0-9]+)', 'Compiled')
$reOut     = [regex]::new('"output_tokens":([0-9]+)', 'Compiled')
$reCc      = [regex]::new('"cache_creation_input_tokens":([0-9]+)', 'Compiled')
$reCr      = [regex]::new('"cache_read_input_tokens":([0-9]+)', 'Compiled')
$re1h      = [regex]::new('"ephemeral_1h_input_tokens":([0-9]+)', 'Compiled')
$ORDINAL = [StringComparison]::Ordinal
$dayEp = @{}
$utf8 = [Text.UTF8Encoding]::new($false)

$fi = 0
foreach ($file in $files) {
  $fi++
  # Share read/write/delete: Claude Code may be appending to this log right now
  try { $fs = [IO.FileStream]::new($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete') }
  catch { continue }
  $sr = [IO.StreamReader]::new($fs, $utf8, $false, 65536)
  $ln = 0
  try {
    while ($null -ne ($line = $sr.ReadLine())) {
      $ln++
      # Only API responses and slash commands matter
      if (-not ($line.Contains('"usage"') -or $line.Contains('"content":"<command-') -or $line.Contains('"role":"user","content":"/'))) { continue }
      # A tool result that merely shows a tag is not a command
      if ($line.Contains('"type":"tool_result"')) { continue }

      # ---- Timestamp: the last match, the top-level field ----
      $m = $reTs.Match($line)
      if (-not $m.Success) { continue }
      $ts = $m.Groups[1].Value
      if (-not $reIso.IsMatch($ts)) { continue }
      $dk = $ts.Substring(0, 10)
      $de = $dayEp[$dk]
      if ($null -eq $de) {
        $dt = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($dk, 'yyyy-MM-dd', $inv, [Globalization.DateTimeStyles]::None, [ref]$dt)) { continue }
        $de = [long]($dt - $epoch0).TotalSeconds
        $dayEp[$dk] = $de
      }
      $ep = $de + [int]$ts.Substring(11, 2) * 3600 + [int]$ts.Substring(14, 2) * 60 + [int]$ts.Substring(17, 2)
      # p = 0 outside the report range; still recorded so an earlier copy of a
      # message keeps a later copy inside the range from being counted
      $p = 0
      for ($q = 1; $q -le $nper; $q++) { if ($ep -ge $ps[$q] -and $ep -lt $pe[$q]) { $p = $q; break } }

      # ---- Slash commands the user typed ----
      # Logged as "<command-name>…" or, for skill commands, "<command-message>…<command-name>…",
      # or as plain text "/name …" (not in subagent prompts, and not a path like /tmp/x).
      $cname = $null
      if ($line.Contains('"content":"<command-')) {
        $cms = $reCmdTag.Matches($line)
        if ($cms.Count -gt 0) {
          $nm = $reCmdName.Match($cms[$cms.Count - 1].Groups[1].Value)
          if ($nm.Success) { $cname = $nm.Groups[1].Value; if ($cname.StartsWith('/')) { $cname = $cname.Substring(1) } }
        }
      }
      if ($null -eq $cname -and $line.Contains('"role":"user","content":"/') -and -not $line.Contains('"isSidechain":true')) {
        $pm = $reCmdText.Match($line)
        if ($pm.Success) { $cname = $pm.Groups[1].Value }
      }
      if ($null -ne $cname) {
        if ($p -gt 0) { $raw_c++ }
        $um = $reUuid.Match($line)
        $ck = if ($um.Success -and $um.Groups[1].Value -ne '') { $um.Groups[1].Value } else { "nouuid:${fi}:$ln" }
        $r = $CMap[$ck]
        if ($null -eq $r) { $r = [CRec]::new(); $r.Ep = $ep; $r.P = $p; $r.Name = '/' + $cname; $CMap[$ck] = $r }
        elseif ($ep -lt $r.Ep) { $r.Ep = $ep; $r.P = $p; $r.Name = '/' + $cname }
      }

      # ---- Tool calls in this assistant message ----
      if ($line.Contains('"type":"tool_use"')) {
        foreach ($tm in $reTool.Matches($line)) {
          $tid = $tm.Groups[1].Value; $tname = $tm.Groups[2].Value
          # This call's input runs up to the next tool_use block
          $st = $tm.Index + $tm.Length
          $nx = $line.IndexOf('"type":"tool_use"', $st, $ORDINAL)
          $tinput = if ($nx -ge 0) { $line.Substring($st, $nx - $st) } else { $line.Substring($st) }
          if ($tname.StartsWith('mcp__')) {
            $server = ($tname -split '__')[1]
            $pre = 'mcp__' + $server + '__'
            $tool = if ($tname.Length -gt $pre.Length) { $tname.Substring($pre.Length) } else { '' }
            EmitT $tid $p 'mcp' $server $ep
            EmitT ($tid + ':m') $p 'mcptool' ($server + ' › ' + $tool) $ep
          }
          else { EmitT $tid $p 'tool' $tname $ep }
          if ($tname -ceq 'Skill') {
            $am = $reSkill.Match($tinput)
            if ($am.Success -and $am.Groups[1].Value -ne '') { EmitT ($tid + ':s') $p 'skill' $am.Groups[1].Value $ep }
          }
          elseif ($tname -ceq 'Bash') {
            $am = $reCommand.Match($tinput)
            if ($am.Success) { $w = BashWord $am.Groups[1].Value; if ($w -ne '') { EmitT ($tid + ':b') $p 'bash' $w $ep } }
          }
          elseif ($tname -ceq 'Read') {
            $am = $reFile.Match($tinput)
            if ($am.Success -and $am.Groups[1].Value -ne '') { EmitT ($tid + ':f') $p 'file' (ShortPath $am.Groups[1].Value) $ep }
          }
          elseif ($tname -ceq 'Agent' -or $tname -ceq 'Task') {
            $am = $reSubType.Match($tinput)
            $an = if ($am.Success -and $am.Groups[1].Value -ne '') { $am.Groups[1].Value } else { 'general-purpose' }
            EmitT ($tid + ':a') $p 'agent' $an $ep
          }
        }
      }

      # ---- Token usage ----
      $ui = $line.IndexOf('"usage":{', $ORDINAL)
      if ($ui -lt 0) { continue }
      $mm = $reModel.Match($line)
      if (-not $mm.Success) { continue }
      $model = $mm.Groups[1].Value
      if ($model -eq '' -or $model -eq '<synthetic>') { continue }
      # Read counts from the usage object only, not from message text
      $x = $reIn.Match($line, $ui);  $tin  = if ($x.Success) { [double]$x.Groups[1].Value } else { 0.0 }
      $x = $reOut.Match($line, $ui); $tout = if ($x.Success) { [double]$x.Groups[1].Value } else { 0.0 }
      $x = $reCc.Match($line, $ui);  $tcc  = if ($x.Success) { [double]$x.Groups[1].Value } else { 0.0 }
      $x = $reCr.Match($line, $ui);  $tcr  = if ($x.Success) { [double]$x.Groups[1].Value } else { 0.0 }
      $x = $re1h.Match($line, $ui);  $t1h  = if ($x.Success) { [double]$x.Groups[1].Value } else { 0.0 }
      if ($t1h -gt $tcc) { $t1h = $tcc }
      if ($tin + $tout + $tcc + $tcr -eq 0) { continue }

      # Dedup key: the API message id, unique per response. Copies of the same
      # response (streamed blocks, resumed or forked sessions) share it, whatever
      # their timestamp, so they are counted once.
      $mid = $mm.Groups[2].Value
      if ($mid -eq '') { $x = $reMsgId.Match($line); if ($x.Success) { $mid = $x.Groups[1].Value } }
      if ($mid -eq '') { $x = $reModelId.Match($line); if ($x.Success) { $mid = $x.Groups[1].Value } }
      $uk = if ($mid -ne '') { $mid } else { "unk_${fi}:$ln" }

      if ($p -gt 0) { $raw_u++ }
      $r = $UMap[$uk]
      if ($null -eq $r -or $ep -lt $r.Ep) {
        if ($null -eq $r) { $r = [URec]::new(); $UMap[$uk] = $r }
        $r.Ep = $ep; $r.P = $p; $r.Date = LocalDate $ep; $r.Model = $model
        $x = $reSid.Match($line); $r.Sid = if ($x.Success) { $x.Groups[1].Value } else { '' }
        $x = $reSide.Match($line); $r.Side = if ($x.Success -and $x.Groups[1].Value -eq 'true') { 1 } else { 0 }
        $x = $reCwd.Match($line); $r.Cwd = if ($x.Success) { $x.Groups[1].Value.Replace('\\', '\') -replace '^.*[/\\]', '' } else { '' }
      }
      # The same call is logged once per streamed block: keep the largest count per field
      if ($tin -gt $r.In) { $r.In = $tin }
      if ($tout -gt $r.Out) { $r.Out = $tout }
      if ($tcc -gt $r.Cc) { $r.Cc = $tcc }
      if ($tcr -gt $r.Cr) { $r.Cr = $tcr }
      if ($t1h -gt $r.C1h) { $r.C1h = $t1h }
    }
  }
  finally { $sr.Dispose() }
}

# ============================ PRICING ============================
$price = NewMap
$loaded_live = 0
foreach ($row in $PriceRows) {
  $price[$row[0] + '|input'] = $row[1]; $price[$row[0] + '|output'] = $row[2]
  $price[$row[0] + '|cache_write'] = $row[3]; $price[$row[0] + '|cache_read'] = $row[4]
  $price[$row[0] + '|cache_write_1h'] = $row[5]
  $loaded_live++
}
function SetPrice([string]$m, [double]$i, [double]$o, [double]$cw, [double]$cr) {
  $price["$m|input"] = $i; $price["$m|output"] = $o; $price["$m|cache_write"] = $cw; $price["$m|cache_read"] = $cr
}
if ($loaded_live -eq 0) {
  # Hardcoded fallback pricing (per 1M tokens): input, output, 5m cache write, cache read.
  # 1-hour cache writes fall back to 2x input in Get-Price.
  SetPrice 'claude-fable-5-1'           10.00 50.00 12.50 0.25
  SetPrice 'claude-fable-5'             10.00 50.00 12.50 1.00
  SetPrice 'claude-opus-5-5'             4.00 20.00  5.00 0.20
  SetPrice 'claude-opus-5'               5.00 25.00  6.25 0.50
  SetPrice 'claude-sonnet-5'             2.00 10.00  2.50 0.20
  SetPrice 'claude-opus-4-6'             5.00 25.00  6.25 0.50
  SetPrice 'claude-opus-4-5-20251101'    5.00 25.00  6.25 0.50
  SetPrice 'claude-sonnet-4-6'           3.00 15.00  3.75 0.30
  SetPrice 'claude-sonnet-4-5-20250929'  3.00 15.00  3.75 0.30
  SetPrice 'claude-haiku-4-5-20251001'   1.00  5.00  1.25 0.10
  SetPrice 'sonnet'                      3.00 15.00  3.75 0.30
}
# Default fallback (always set)
SetPrice 'default' 3.00 15.00 3.75 0.30
$unpriced = NewMap

function Get-Price([string]$model, [string]$type) {
  # 1-hour cache writes cost 2x input when no explicit price is known
  if ($type -eq 'cache_write_1h' -and -not $price.ContainsKey("$model|$type") -and $price.ContainsKey("$model|input")) {
    return 2 * $price["$model|input"]
  }
  if ($price.ContainsKey("$model|$type")) { return $price["$model|$type"] }
  if ($price.ContainsKey("anthropic/$model|$type")) { return $price["anthropic/$model|$type"] }
  $m = ($model -creplace '-20[0-9]+$', '' -creplace '-thinking$', '').Replace('.', '-')
  if ($price.ContainsKey("$m|$type")) { return $price["$m|$type"] }
  if ($price.ContainsKey("anthropic/$m|$type")) { return $price["anthropic/$m|$type"] }
  if ($type -eq 'cache_write_1h') { return 2 * (Get-Price $model 'input') }
  $unpriced[$model] = 1
  return $price["default|$type"]
}
$priceVec = NewMap
function PriceVec([string]$model) {
  $v = $priceVec[$model]
  if ($null -eq $v) {
    $v = [double[]]@((Get-Price $model 'input'), (Get-Price $model 'output'), (Get-Price $model 'cache_write'),
                     (Get-Price $model 'cache_read'), (Get-Price $model 'cache_write_1h'))
    $priceVec[$model] = $v
  }
  , $v
}

# ============================ AGGREGATE ============================
$months = @('', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec')
$cats = @('tool', 'mcp', 'skill', 'cmd', 'agent')
# the HTML report also lists individual MCP tools, Bash commands, files and projects
$hcats = @('tool', 'mcp', 'mcptool', 'bash', 'file', 'skill', 'cmd', 'agent', 'project')
$cat_title = @{ tool = 'Tools'; mcp = 'MCP servers'; skill = 'Skills'; cmd = 'Slash commands'; agent = 'Subagents'
                mcptool = 'MCP tools'; project = 'Projects (API calls)'; bash = 'Bash commands'; file = 'Files read' }

function NewArr([int]$n) { , (New-Object double[] $n) }
function NewMaps { $a = New-Object object[] 7; for ($j = 0; $j -lt 7; $j++) { $a[$j] = NewMap }; , $a }
function NewHists([int]$n) { $a = New-Object object[] 7; for ($j = 0; $j -lt 7; $j++) { $a[$j] = New-Object double[] $n }; , $a }

# cnt[cat][p][key], ctot[cat][key], csum[cat][p]
$cnt = @{}; $ctot = @{}; $csum = @{}
foreach ($c in $hcats) { $cnt[$c] = NewMaps; $ctot[$c] = NewMap; $csum[$c] = NewArr 7 }
function Bump([string]$cat, [int]$p, [string]$key) {
  $m = $cnt[$cat][$p]; $m[$key] = 1 + $m[$key]
  $t = $ctot[$cat]; $t[$key] = 1 + $t[$key]
  $csum[$cat][$p] += 1
}
function Cnt([string]$cat, [int]$p, [string]$key) { $v = $cnt[$cat][$p][$key]; if ($null -eq $v) { 0 } else { $v } }

# Records whose earliest copy is outside the range (period 0) are dropped here
$uniq_t = 0; $uniq_c = 0
foreach ($r in $TMap.Values) {
  if ($r.P -eq 0) { continue }
  Bump $r.Cat $r.P $r.Name
  if ($r.Cat -eq 'tool' -or $r.Cat -eq 'mcp') { $uniq_t++ }
}
foreach ($r in $CMap.Values) { if ($r.P -eq 0) { continue }; Bump 'cmd' $r.P $r.Name; $uniq_c++ }
$inr = [Collections.Generic.List[object]]::new()
foreach ($r in $UMap.Values) { if ($r.P -gt 0) { $inr.Add($r) } }
$uniq_u = $inr.Count

# ---- Context size ----
# One API call re-sends the whole conversation, so its context is input + cache write + cache read.
# Main conversation only (subagents start small and would pull the numbers down); they get their own row.
# Percentiles come from fixed-width bins (CTX_BIN tokens) instead of a sort: exact to one bin, and fast.
$CTX_BIN = 5000; $CTX_MAXBIN = 260       # up to 1.3M tokens
$CTX_MAXIDX = 400; $CTX_MINSESS = 5      # chart: call numbers 1..400, while at least 5 sessions get that far
$CALL_CAP = 3000
function CtxBin([double]$x) { $b = [long][math]::Floor($x / $CTX_BIN); if ($b -gt $CTX_MAXBIN) { $CTX_MAXBIN } else { $b } }
$CT_n = NewArr 7; $CT_sum = NewArr 7; $CT_max = NewArr 7; $CT_h = NewHists ($CTX_MAXBIN + 1)
$SA_n = NewArr 7; $SA_sum = NewArr 7; $SA_h = NewHists ($CTX_MAXBIN + 1)
$SS_n = NewArr 7; $SS_calls_sum = NewArr 7; $SS_calls_h = NewHists ($CALL_CAP + 1); $SS_pk_sum = NewArr 7; $SS_pk_h = NewHists ($CTX_MAXBIN + 1)
$IX_n = NewArr ($CTX_MAXIDX + 1); $IX_sum = NewArr ($CTX_MAXIDX + 1); $IX_h = New-Object object[] ($CTX_MAXIDX + 1)
function NoteCall([int]$p, [double]$ctx) {
  $CT_n[$p] += 1; $CT_sum[$p] += $ctx; $CT_h[$p][(CtxBin $ctx)] += 1
  if ($ctx -gt $CT_max[$p]) { $CT_max[$p] = $ctx }
}
$sess = NewMap
# every copy counts toward call numbers in a session, even when its earliest copy is outside the range
foreach ($r in $UMap.Values) {
  $ctx = $r.In + $r.Cc + $r.Cr
  $p = $r.P
  if ($r.Side) {
    if ($p -gt 0) { $SA_n[$p] += 1; $SA_sum[$p] += $ctx; $SA_h[$p][(CtxBin $ctx)] += 1 }
    continue
  }
  if ($r.Sid -eq '') { if ($p -gt 0) { NoteCall $p $ctx }; continue }
  $l = $sess[$r.Sid]
  if ($null -eq $l) { $l = [Collections.Generic.List[object]]::new(); $sess[$r.Sid] = $l }
  $l.Add($r)
}
foreach ($l in $sess.Values) {
  $n = $l.Count
  # sort the session's calls by time (an index array: PowerShell would sort a copy of object[] items)
  $eps = New-Object long[] $n; $ord = New-Object int[] $n
  for ($j = 0; $j -lt $n; $j++) { $eps[$j] = $l[$j].Ep; $ord[$j] = $j }
  [Array]::Sort($eps, $ord)
  $nc = 0; $pk = 0.0; $sp1 = 0
  for ($j = 1; $j -le $n; $j++) {
    $r = $l[$ord[$j - 1]]
    $p = $r.P
    if ($p -eq 0) { continue }
    $ctx = $r.In + $r.Cc + $r.Cr
    NoteCall $p $ctx
    if ($sp1 -eq 0) { $sp1 = $p }
    $nc++
    if ($ctx -gt $pk) { $pk = $ctx }
    if ($j -le $CTX_MAXIDX) {
      if ($null -eq $IX_h[$j]) { $IX_h[$j] = New-Object double[] ($CTX_MAXBIN + 1) }
      $IX_n[$j] += 1; $IX_sum[$j] += $ctx; $IX_h[$j][(CtxBin $ctx)] += 1
    }
  }
  if ($nc -gt 0) {
    $SS_n[$sp1] += 1; $SS_calls_sum[$sp1] += $nc; $SS_calls_h[$sp1][[math]::Min($nc, $CALL_CAP)] += 1
    $SS_pk_sum[$sp1] += $pk; $SS_pk_h[$sp1][(CtxBin $pk)] += 1
  }
}
$ix_max = 0
for ($j = 1; $j -le $CTX_MAXIDX; $j++) { if ($IX_n[$j] -lt $CTX_MINSESS) { break }; $ix_max = $j }

# ---- Chart buckets: sortable key for the local hour, day, week (Monday) or month ----
function BucketKey([long]$ep, [string]$unit) {
  $lep = $ep + $tzs
  $dn = [long][math]::Floor($lep / 86400)
  $d = DayStr $dn
  switch ($unit) {
    'hour' { return $d + ' ' + ([math]::Floor(($lep - $dn * 86400) / 3600)).ToString('00', $inv) }
    'day'  { return $d }
    'week' {
      # a week that starts before its period is clipped to the period start
      $ws = DayStr ($dn - (($dn + 3) % 7))
      $p = PeriodOf $ep
      if ($p -gt 0 -and $ps[$p] -gt 0) { $pd = LocalDate $ps[$p]; if ([string]::CompareOrdinal($ws, $pd) -lt 0) { $ws = $pd } }
      return $ws
    }
  }
  $d.Substring(0, 7)
}
function BucketLabel([string]$k, [string]$unit) {
  $m = $months[[int]$k.Substring(5, 2)]
  switch ($unit) {
    'hour' { return $m + ' ' + [int]$k.Substring(8, 2) + ' ' + $k.Substring(11, 2) + ':00' }
    'day'  { return $m + ' ' + [int]$k.Substring(8, 2) }
    'week' { return 'Week of ' + $m + ' ' + [int]$k.Substring(8, 2) }
  }
  $m + ' ' + $k.Substring(0, 4)
}
# Short x-axis tick
function BucketTick([string]$k, [string]$unit) {
  $m = $months[[int]$k.Substring(5, 2)]
  if ($unit -eq 'hour') { if ($k.Substring(11, 2) -eq '00') { return $m + ' ' + [int]$k.Substring(8, 2) } else { return $k.Substring(11, 2) + 'h' } }
  if ($unit -eq 'month') { return $m + ' ' + $k.Substring(2, 2) }
  $m + ' ' + [int]$k.Substring(8, 2)
}
function UnitWord([string]$unit) { if ($unit -in 'hour', 'day', 'week') { $unit } else { 'month' } }

# ---- Chart step: given, or picked from the span of the data ----
$min_ep = [long]0; $max_ep = [long]0
foreach ($r in $inr) {
  if ($min_ep -eq 0 -or $r.Ep -lt $min_ep) { $min_ep = $r.Ep }
  if ($r.Ep -gt $max_ep) { $max_ep = $r.Ep }
}
# chart range: the compared periods, or the data itself for one open range
$r_from = if ($ps[1] -gt 0) { $ps[1] } else { $min_ep }
$r_to = if ($pe[$nper] -lt $NOW) { $pe[$nper] } else { $NOW }
if ($nper -eq 1 -and $pe[1] -gt $NOW) { $r_to = if ($max_ep -gt 0) { $max_ep } else { $NOW } }
$bucket_unit = $BUCKET
if ($bucket_unit -eq 'auto') {
  $span = $r_to - $r_from
  if ($span -le 2 * 86400) { $bucket_unit = 'hour' }
  elseif ($span -le 45 * 86400) { $bucket_unit = 'day' }
  elseif ($span -le 200 * 86400) { $bucket_unit = 'week' }
  else { $bucket_unit = 'month' }
}
$B_cost = NewMap; $B_cost_p = NewMap; $B_calls = NewMap; $B_cr = NewMap; $B_in = NewMap
# every bucket in the range, so empty ones show as zero
if ($min_ep -gt 0 -and $r_from -gt 0) {
  for ($t = $r_from; $t -lt $r_to; $t += 3600) { $k = BucketKey $t $bucket_unit; if (-not $B_cost.ContainsKey($k)) { $B_cost[$k] = 0.0 } }
  if ($r_to -gt $r_from) { $k = BucketKey ($r_to - 1) $bucket_unit; if (-not $B_cost.ContainsKey($k)) { $B_cost[$k] = 0.0 } }
}

# ---- Aggregate from deduplicated messages ----
$total_input = 0.0; $total_output = 0.0; $total_ccreate = 0.0; $total_cread = 0.0; $total_cost = 0.0; $nocache_cost = 0.0
$P_calls = NewArr 7; $P_in = NewArr 7; $P_out = NewArr 7; $P_cw5 = NewArr 7; $P_cw1h = NewArr 7; $P_cr = NewArr 7
$P_cin = NewArr 7; $P_cout = NewArr 7; $P_ccw = NewArr 7; $P_ccr = NewArr 7; $P_cost = NewArr 7; $P_nc = NewArr 7
$mod_cost = NewMap; $mod_calls = NewMap
$PM_calls = NewMaps; $PM_cost = NewMaps
$day_cost = NewMap; $month_cost = NewMap; $month_tokens = NewMap
$PJ_c = NewMaps; $PJ_n = NewMaps; $PJ_t = NewMap
$TH_n = NewHists 24; $TH_c = NewHists 24; $TW_n = NewHists 7; $TW_c = NewHists 7

foreach ($r in $inr) {
  $p = $r.P; $model = $r.Model; $date = $r.Date
  $pv = PriceVec $model
  $cost_input  = $r.In * $pv[0] / 1000000
  $cost_output = $r.Out * $pv[1] / 1000000
  $cost_cwrite = ($r.Cc - $r.C1h) * $pv[2] / 1000000 + $r.C1h * $pv[4] / 1000000
  $cost_cread  = $r.Cr * $pv[3] / 1000000
  $line_cost   = $cost_input + $cost_output + $cost_cwrite + $cost_cread
  $line_nocache = ($r.In + $r.Cc + $r.Cr) * $pv[0] / 1000000 + $cost_output

  $total_input += $r.In; $total_output += $r.Out; $total_ccreate += $r.Cc; $total_cread += $r.Cr
  $total_cost += $line_cost; $nocache_cost += $line_nocache

  # per period
  $P_calls[$p] += 1
  $P_in[$p] += $r.In; $P_out[$p] += $r.Out; $P_cw5[$p] += $r.Cc - $r.C1h; $P_cw1h[$p] += $r.C1h; $P_cr[$p] += $r.Cr
  $P_cin[$p] += $cost_input; $P_cout[$p] += $cost_output; $P_ccw[$p] += $cost_cwrite; $P_ccr[$p] += $cost_cread
  $P_cost[$p] += $line_cost; $P_nc[$p] += $line_nocache

  # per model (all periods, and per period)
  $mod_cost[$model] += $line_cost; $mod_calls[$model] += 1
  $h = $PM_calls[$p]; $h[$model] += 1
  $h = $PM_cost[$p]; $h[$model] += $line_cost

  $day_cost[$date] += $line_cost

  $bk = BucketKey $r.Ep $bucket_unit
  $B_cost[$bk] += $line_cost
  $bp = $B_cost_p[$bk]; if ($null -eq $bp) { $bp = New-Object double[] 7; $B_cost_p[$bk] = $bp }
  $bp[$p] += $line_cost
  $B_calls[$bk] += 1
  $B_cr[$bk] += $r.Cr
  $B_in[$bk] += $r.In + $r.Cc + $r.Cr

  $proj = if ($r.Cwd -ne '') { $r.Cwd } else { '(unknown)' }
  Bump 'project' $p $proj
  $h = $PJ_c[$p]; $h[$proj] += $line_cost
  $h = $PJ_n[$p]; $h[$proj] += 1
  $PJ_t[$proj] += $line_cost
  $lep = $r.Ep + $tzs
  $dn = [long][math]::Floor($lep / 86400)
  $hh = [int][math]::Floor(($lep - $dn * 86400) / 3600)
  $wd = [int](($dn + 3) % 7)   # 1970-01-01 was a Thursday; Monday = 0
  $TH_n[$p][$hh] += 1; $TH_c[$p][$hh] += $line_cost; $TW_n[$p][$wd] += 1; $TW_c[$p][$wd] += $line_cost

  $ym = $date.Substring(0, 7)
  $month_cost[$ym] += $line_cost
  $month_tokens[$ym] += $r.In + $r.Out + $r.Cc + $r.Cr
}

# ============================ FORMATTING ============================
function F([double]$x, [string]$fmt) { $x.ToString($fmt, $inv) }
# like printf %g for the small numbers used on chart axes
function G([double]$x) { $x.ToString('0.######', $inv) }
function SignF([double]$d, [int]$dec) { $s = [math]::Abs($d).ToString("F$dec", $inv); if ($d -lt 0) { '-' + $s } else { '+' + $s } }
function Commas([double]$n) { [math]::Round($n, [MidpointRounding]::AwayFromZero).ToString('#,0', $inv) }
function Money([double]$x) { if ($x -lt 10) { '$' + $x.ToString('F2', $inv) } else { '$' + (Commas $x) } }
function Pct([double]$a, [double]$b) { if ($b -gt 0) { ($a / $b * 100).ToString('F1', $inv) + '%' } else { '–' } }
function FmtTok([double]$t) {
  if ($t -ge 1000000000) { return ($t / 1000000000).ToString('F2', $inv) + 'B' }
  if ($t -ge 1000000) { return ($t / 1000000).ToString('F1', $inv) + 'M' }
  if ($t -ge 1000) { return ($t / 1000).ToString('F1', $inv) + 'K' }
  [math]::Truncate($t).ToString('0', $inv)
}
function Rep([string]$s, [int]$n) { if ($n -le 0) { '' } else { $s * $n } }
function PadL([string]$s, [int]$w) { (Rep ' ' ($w - $s.Length)) + $s }
function PadR([string]$s, [int]$w) { $s + (Rep ' ' ($w - $s.Length)) }
function Sub([string]$s, [int]$n) { if ($s.Length -gt $n) { $s.Substring(0, $n) } else { $s } }
function Hesc([string]$s) { $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&#39;') }
# 1, 2 or 5 times a power of ten, at or above x
function NiceMax([double]$x) {
  if ($x -le 0) { return 1 }
  $e = [math]::Pow(10, [math]::Truncate([math]::Log10($x)))
  $f = $x / $e
  if ($f -le 1) { return $e }
  if ($f -le 2) { return 2 * $e }
  if ($f -le 5) { return 5 * $e }
  10 * $e
}
# Keys ordered by value, highest first (ties by name)
function SortDesc($map) {
  # ties by name, compared byte by byte (Sort-Object would ignore case, unlike claude-stats.sh)
  $items = [Collections.Generic.List[object]]::new([object[]]@($map.GetEnumerator()))
  $items.Sort([Comparison[object]]{ param($x, $y)
    $c = ([double]$y.Value).CompareTo([double]$x.Value)
    if ($c -ne 0) { return $c }
    [string]::CompareOrdinal([string]$x.Key, [string]$y.Key)
  })
  $keys = New-Object string[] $items.Count
  for ($i = 0; $i -lt $items.Count; $i++) { $keys[$i] = [string]$items[$i].Key }
  , $keys
}
function SortKeys($map) { $a = New-Object string[] $map.Count; $map.Keys.CopyTo($a, 0); [Array]::Sort($a, [StringComparer]::Ordinal); , $a }

# ============================ TERMINAL REPORT ============================
$sb = [Text.StringBuilder]::new()
function Out([string]$s) { [void]$sb.Append($s) }

if ($inr.Count -eq 0) {
  Out "`n  No usage found in this range.`n"
  Write-Output ($sb.ToString() + "`n")
  exit 0
}

$total_tokens = $total_input + $total_output + $total_ccreate + $total_cread
$num_active = $day_cost.Count
$peak_cost = 0.0; $peak_day = ''
foreach ($d in $day_cost.Keys) { if ($day_cost[$d] -gt $peak_cost) { $peak_cost = $day_cost[$d]; $peak_day = $d } }
$peak_label = if ($peak_day) { $months[[int]$peak_day.Substring(5, 2)] + ' ' + [int]$peak_day.Substring(8, 2) } else { '' }

$CR = tc '0'; $CB = tc '1'; $CD = tc '2'; $CG = tc '32'; $CRD = tc '31'; $CC = tc '36'
$pcn = @(69, 208, 36, 168, 141)
$PC = @(''); for ($p = 1; $p -le $nper; $p++) { $PC += tc ('38;5;' + $pcn[($p - 1) % 5]) }
$kcn = @(75, 214, 43, 245)
$KC = @(''); for ($j = 1; $j -le 4; $j++) { $KC += tc ('38;5;' + $kcn[$j - 1]) }
$shade = @('', '█', '▓', '▒', '░')

function Section([string]$t) { Out ("`n  " + $CB + $CC + '▍' + $t + $CR + "`n`n") }

# One comparison row; style "b" bold, "d" dim label; change is the "vs prev" cell
function CRow([string]$label, $vals, [string]$style, [string]$change) {
  if ($style -eq 'b') { Out ('  ' + $CB + (PadR $label 22) + $CR) }
  elseif ($style -eq 'd') { Out ('  ' + $CD + (PadR $label 22) + $CR) }
  else { Out ('  ' + (PadR $label 22)) }
  $bold = if ($style -eq 'b') { $CB } else { '' }
  for ($p = 1; $p -le $nper; $p++) { Out (' ' + $bold + (PadL $vals[$p] $colw) + $CR) }
  if ($nper -gt 1) { Out (' ' + $change) }
  Out "`n"
}

# Change of the last period against the one before, as a 10-wide cell.
# cost colours a rise red and a fall green; otherwise it stays dim.
function Chg($arr, [bool]$cost) {
  if ($nper -lt 2) { return '' }
  $a = [double]$arr[$nper - 1]; $b = [double]$arr[$nper]
  if ($a -eq 0) { return $CD + (PadL '–' 10) + $CR }
  $d = ($b - $a) / $a * 100
  $col = $CD
  if ($cost -and $d -ge 0.5) { $col = $CRD }
  if ($cost -and $d -le -0.5) { $col = $CG }
  $col + (PadL ((SignF $d 0) + '%') 10) + $CR
}
function ChgPt($arr) {
  if ($nper -lt 2) { return '' }
  $d = [double]$arr[$nper] - [double]$arr[$nper - 1]
  if ($d -gt -0.05 -and $d -lt 0.05) { $d = 0 }   # no "-0.0 pt"
  $col = if ($d -gt 0.05) { $CG } elseif ($d -lt -0.05) { $CRD } else { $CD }
  $col + (PadL ((SignF $d 1) + ' pt') 10) + $CR
}

# Horizontal bar with eighth-block resolution, padded to width cells
function HBar([double]$frac, [int]$width) {
  if ($frac -lt 0) { $frac = 0 }
  if ($frac -gt 1) { $frac = 1 }
  $cells = $frac * $width
  $full = [int][math]::Floor($cells)
  $part = [int][math]::Floor(($cells - $full) * 8)
  $s = Rep '█' $full
  if ($part -gt 0) { $s += '▏▎▍▌▋▊▉'.Substring($part - 1, 1); $full++ }
  elseif ($full -eq 0 -and $frac -gt 0) { $s = '▏'; $full = 1 }
  $s + (Rep ' ' ($width - $full))
}

# Stacked bar of the four cost kinds, width cells
function StackBar($amounts, [double]$total, [int]$width) {
  if ($total -le 0) { return Rep ' ' $width }
  $s = ''; $used = 0
  for ($j = 1; $j -le 4; $j++) {
    $w = if ($j -eq 4) { $width - $used } else { [int][math]::Floor($amounts[$j] / $total * $width + 0.5) }
    if ($used + $w -gt $width) { $w = $width - $used }
    if ($w -lt 0) { $w = 0 }
    # without colour each kind gets its own shade so the split stays readable
    $ch = if ($NOCOLOR) { $shade[$j] } else { '█' }
    $s += $KC[$j] + (Rep $ch $w) + $CR
    $used += $w
  }
  $s
}

function PrintTop([string]$cat) {
  $tot = $ctot[$cat]
  Section ('Top ' + $cat_title[$cat])
  if ($tot.Count -eq 0) { Out ('  ' + $CD + '(none)' + $CR + "`n"); return }
  $ord = SortDesc $tot
  $n = $ord.Count
  $lim = [math]::Min($n, $top_n)
  $nw = 34
  Out ('  ' + (PadR '' $nw))
  for ($p = 1; $p -le $nper; $p++) { Out (' ' + $PC[$p] + $CB + (PadL (Sub $plab[$p] 10) 10) + $CR) }
  if ($nper -gt 1) { Out (' ' + $CB + (PadL 'Total' 10) + $CR) }
  $extra = if ($nper -gt 1) { 1 } else { 0 }
  Out ("`n  " + $CD + (Rep '─' ($nw + 11 * ($nper + $extra))) + $CR + "`n")
  for ($i = 0; $i -lt $lim; $i++) {
    $key = $ord[$i]
    Out ('  ' + (PadR (Sub $key $nw) $nw))
    for ($p = 1; $p -le $nper; $p++) {
      $c = Cnt $cat $p $key
      if ($c -eq 0) { Out (' ' + $CD + (PadL '–' 10) + $CR) } else { Out (' ' + (PadL (Commas $c) 10)) }
    }
    if ($nper -gt 1) { Out (' ' + $CB + (PadL (Commas $tot[$key]) 10) + $CR) }
    Out "`n"
  }
  if ($n -gt $lim) { Out ('  ' + $CD + '… ' + ($n - $lim) + ' more' + $CR + "`n") }
}

# ---- Header ----
$pricing_desc = if ($loaded_live -gt 0) { "LiteLLM ($loaded_live models)" } else { 'hardcoded' }
Out ("`n  " + $CB + 'Claude Code usage' + $CR + '  ' + $CD + '· estimated at API list prices · pricing ' + $pricing_desc + $CR + "`n`n")
for ($p = 1; $p -le $nper; $p++) {
  Out ('  ' + $PC[$p] + '■' + $CR + ' ' + $CB + (PadR $plab[$p] 11) + $CR + ' ' + $CD + $plong[$p] + $CR + "`n")
}
$tin_all = $total_input + $total_ccreate + $total_cread
Out ("`n  " + $CB + 'Total' + $CR + '  ' + $CB + $CG + (Money $total_cost) + $CR + '  ·  ' + (Commas $uniq_u) + ' calls  ·  ' +
     (FmtTok $total_tokens) + ' tokens  ·  hit rate ' + (Pct $total_cread $tin_all) + '  ·  ' + $num_active + ' active days  ·  peak ' +
     $peak_label + ' ' + (Money $peak_cost) + "`n")

# ---- Comparison (or summary for one period) ----
$colw = if ($nper -gt 3) { 17 } else { 20 }
Section $(if ($nper -gt 1) { 'Comparison' } else { 'Summary' })
Out ('  ' + (PadR '' 22))
for ($p = 1; $p -le $nper; $p++) { Out (' ' + $PC[$p] + $CB + (PadL (Sub $plab[$p] $colw) $colw) + $CR) }
if ($nper -gt 1) { Out (' ' + $CD + (PadL 'vs prev' 10) + $CR) }
Out ("`n  " + $CD + (Rep '─' (22 + ($colw + 1) * $nper + $(if ($nper -gt 1) { 11 } else { 0 }))) + $CR + "`n")
$v = New-Object string[] 7; $tv = NewArr 7; $hr = NewArr 7
for ($p = 1; $p -le $nper; $p++) { $v[$p] = Commas $P_calls[$p] }; CRow 'API calls' $v '' (Chg $P_calls $false)
for ($p = 1; $p -le $nper; $p++) { $tv[$p] = $P_in[$p] + $P_cw5[$p] + $P_cw1h[$p] + $P_cr[$p]; $v[$p] = FmtTok $tv[$p] }; CRow 'Input tokens' $v '' (Chg $tv $false)
for ($p = 1; $p -le $nper; $p++) { $v[$p] = (FmtTok $P_cr[$p]) + ' · ' + (Money $P_ccr[$p]) }; CRow '  Cache read (hit)' $v 'd' (Chg $P_ccr $true)
for ($p = 1; $p -le $nper; $p++) { $v[$p] = FmtTok $P_cw5[$p] }; CRow '  Cache write 5 min' $v 'd' (Chg $P_cw5 $false)
for ($p = 1; $p -le $nper; $p++) { $v[$p] = FmtTok $P_cw1h[$p] }; CRow '  Cache write 1 hour' $v 'd' (Chg $P_cw1h $false)
for ($p = 1; $p -le $nper; $p++) { $v[$p] = (FmtTok ($P_cw5[$p] + $P_cw1h[$p])) + ' · ' + (Money $P_ccw[$p]) }; CRow '  Cache writes (miss)' $v 'd' (Chg $P_ccw $true)
for ($p = 1; $p -le $nper; $p++) { $v[$p] = (FmtTok $P_in[$p]) + ' · ' + (Money $P_cin[$p]) }; CRow '  Not cached (miss)' $v 'd' (Chg $P_cin $true)
for ($p = 1; $p -le $nper; $p++) { $hr[$p] = if ($tv[$p] -gt 0) { $P_cr[$p] / $tv[$p] * 100 } else { 0 }; $v[$p] = Pct $P_cr[$p] $tv[$p] }; CRow '  Cache hit rate' $v 'd' (ChgPt $hr)
for ($p = 1; $p -le $nper; $p++) { $v[$p] = (FmtTok $P_out[$p]) + ' · ' + (Money $P_cout[$p]) }; CRow 'Output tokens' $v '' (Chg $P_cout $true)
for ($p = 1; $p -le $nper; $p++) { $v[$p] = Money $P_cost[$p] }; CRow 'Est. API cost' $v 'b' (Chg $P_cost $true)
for ($p = 1; $p -le $nper; $p++) { $v[$p] = Money $P_nc[$p] }; CRow 'Cost with no cache' $v 'd' (Chg $P_nc $false)

# ---- Where the money goes ----
Section 'Where the money goes'
$kname = @('', 'Cache read', 'Cache write', 'Output', 'Input')
Out '  '
for ($j = 1; $j -le 4; $j++) { Out ($KC[$j] + $(if ($NOCOLOR) { $shade[$j] } else { '■' }) + $CR + ' ' + $kname[$j] + '   ') }
Out "`n`n"
for ($p = 1; $p -le $nper; $p++) {
  $kcost = @(0, $P_ccr[$p], $P_ccw[$p], $P_cout[$p], $P_cin[$p])
  Out ('  ' + $PC[$p] + (PadR (Sub $plab[$p] 11) 11) + $CR + ' ' + (StackBar $kcost $P_cost[$p] 40) + ' ' + $CB + (PadL (Money $P_cost[$p]) 10) + $CR +
       '  ' + $CD + 'read ' + (Pct $kcost[1] $P_cost[$p]) + ' · write ' + (Pct $kcost[2] $P_cost[$p]) + ' · output ' + (Pct $kcost[3] $P_cost[$p]) + $CR + "`n")
}
$saved_pct = if ($nocache_cost -gt 0) { ($nocache_cost - $total_cost) / $nocache_cost * 100 } else { 0 }
Out ("`n  Caching saved " + $CB + $CG + (Money ($nocache_cost - $total_cost)) + $CR + ': the same tokens without cache would cost ' +
     (Money $nocache_cost) + ' (' + (F $saved_pct 'F0') + "% less).`n")

# ---- Cost chart, one step below the compared period ----
Section ('Cost per ' + (UnitWord $bucket_unit))
$sorted_buckets = SortKeys $B_cost
$max_cost = 0.0
foreach ($bk in $sorted_buckets) { if ($B_cost[$bk] -gt $max_cost) { $max_cost = $B_cost[$bk] } }
if ($max_cost -le 0) { $max_cost = 1 }
$lw = 0
foreach ($bk in $sorted_buckets) { $len = (BucketLabel $bk $bucket_unit).Length; if ($len -gt $lw) { $lw = $len } }
foreach ($bk in $sorted_buckets) {
  # colour a bar by the period holding most of its cost
  $bp = 1; $bmax = -1.0; $arr = $B_cost_p[$bk]
  for ($p = 1; $p -le $nper; $p++) { $c = if ($null -ne $arr) { $arr[$p] } else { 0 }; if ($c -gt $bmax) { $bmax = $c; $bp = $p } }
  Out ('  ' + (PadR (BucketLabel $bk $bucket_unit) $lw) + '  ' + $PC[$bp] + (HBar ($B_cost[$bk] / $max_cost) 36) + $CR + ' ' +
       (PadL (Money $B_cost[$bk]) 9) + '  ' + $CD + (Commas $B_calls[$bk]) + ' calls' + $CR + "`n")
}

# ---- Models ----
Section 'Models'
$mord = SortDesc $mod_cost
$mw = if ($nper -gt 3) { 10 } else { 12 }
$extra = if ($nper -gt 1) { 1 } else { 0 }
Out ('  ' + $CD + (PadR 'Model' 28) + $CR)
for ($p = 1; $p -le $nper; $p++) { Out (' ' + $PC[$p] + $CB + (PadL (Sub $plab[$p] $mw) $mw) + $CR) }
if ($nper -gt 1) { Out (' ' + $CB + (PadL 'Total' $mw) + $CR) }
Out (' ' + $CD + (PadL 'Share' 7) + ' ' + (PadL 'Calls' 9) + $CR + "`n")
Out ('  ' + $CD + (Rep '─' (28 + ($mw + 1) * ($nper + $extra) + 18)) + $CR + "`n")
foreach ($mk in $mord) {
  $star = if ($unpriced.ContainsKey($mk)) { ' *' } else { '' }
  Out ('  ' + (PadR ((Sub $mk 26) + $star) 28))
  for ($p = 1; $p -le $nper; $p++) {
    if ([double]$PM_calls[$p][$mk] -eq 0) { Out (' ' + $CD + (PadL '–' $mw) + $CR) }
    else { Out (' ' + (PadL (Money $PM_cost[$p][$mk]) $mw)) }
  }
  if ($nper -gt 1) { Out (' ' + $CB + (PadL (Money $mod_cost[$mk]) $mw) + $CR) }
  Out (' ' + (PadL (Pct $mod_cost[$mk] $total_cost) 7) + ' ' + (PadL (Commas $mod_calls[$mk]) 9) + "`n")
}
if ($unpriced.Count -gt 0) { Out ("`n  " + $CD + '* no price found; costed at default Sonnet rates' + $CR + "`n") }

# ---- Monthly breakdown: only for one range that spans several months ----
$sorted_months = SortKeys $month_cost
if ($nper -eq 1 -and $sorted_months.Count -gt 1) {
  Section 'By month'
  foreach ($ym in $sorted_months) {
    Out ('  ' + (PadR ($months[[int]$ym.Substring(5, 2)] + ' ' + $ym.Substring(0, 4)) 10) + ' ' + (PadL (FmtTok $month_tokens[$ym]) 12) + ' ' + (PadL (Money $month_cost[$ym]) 10) + "`n")
  }
}

# ---- Top tools / MCP / skills / commands / subagents ----
foreach ($cat in $cats) { PrintTop $cat }

# ---- Uniqueness ----
Section 'Counted once each'
Out ('  ' + $CD + (PadR '' 22) + ' ' + (PadL 'Log lines' 12) + ' ' + (PadL 'Unique' 12) + ' ' + (PadL 'Copies' 12) + '   Unique by' + $CR + "`n")
Out ('  ' + (PadR 'API responses' 22) + ' ' + (PadL (Commas $raw_u) 12) + ' ' + (PadL (Commas $uniq_u) 12) + ' ' + (PadL (Commas ($raw_u - $uniq_u)) 12) + '   ' + $CD + 'message id' + $CR + "`n")
Out ('  ' + (PadR 'Tool and MCP calls' 22) + ' ' + (PadL (Commas $raw_t) 12) + ' ' + (PadL (Commas $uniq_t) 12) + ' ' + (PadL (Commas ($raw_t - $uniq_t)) 12) + '   ' + $CD + 'tool_use id' + $CR + "`n")
Out ('  ' + (PadR 'Slash commands' 22) + ' ' + (PadL (Commas $raw_c) 12) + ' ' + (PadL (Commas $uniq_c) 12) + ' ' + (PadL (Commas ($raw_c - $uniq_c)) 12) + '   ' + $CD + 'message uuid' + $CR + "`n")
Out ('  ' + $CD + 'Copies come from streamed replies (one line per block) and resumed or forked sessions.' + $CR + "`n")
Out ("`n  " + $CD + 'Costs are estimates at API list prices, not your subscription bill.' + $CR + "`n")

# ============================ HTML REPORT ============================
$HtmlLines = [Collections.Generic.List[string]]::new()
function o([string]$s) { $HtmlLines.Add($s) }
function PColor([int]$p) { 'var(--p' + (($p - 1) % 5 + 1) + ')' }
function TinOf([int]$p) { $P_in[$p] + $P_cw5[$p] + $P_cw1h[$p] + $P_cr[$p] }
function Pcts([double]$a, [double]$b) { if ($b -gt 0) { $a / $b * 100 } else { 0 } }
# Status color for a number: g = healthy, b = worth a look, r = needs attention (hover shows why)
function Paint([string]$l, [string]$text, [string]$tip) { "<span class='sv $l' title='" + (Hesc $tip) + "'>" + $text + '</span>' }
function LvlHi([double]$x, [double]$g, [double]$b) { if ($x -ge $g) { 'g' } elseif ($x -ge $b) { 'b' } else { 'r' } }   # higher is better
function LvlLo([double]$x, [double]$g, [double]$b) { if ($x -lt $g) { 'g' } elseif ($x -le $b) { 'b' } else { 'r' } }   # lower is better
function KFmt([double]$x) { if ($x -ge 1000000) { (G ($x / 1000000)) + 'M' } else { (G ($x / 1000)) + 'k' } }
function PeriodHeads { for ($p = 1; $p -le $nper; $p++) { o ("<th><i class='chip' style='background:" + (PColor $p) + "'></i>" + (Hesc $plab[$p]) + '</th>') } }
function PeriodKeys { for ($p = 1; $p -le $nper; $p++) { o ("<span><i class='chip' style='background:" + (PColor $p) + "'></i>" + (Hesc $plab[$p]) + '</span>') } }

function HRow([string]$label, $vals, [string]$cls) {
  $c = if ($cls -ne '') { " class='$cls'" } else { '' }
  o ('<tr' + $c + '><td>' + $label + '</td>')
  for ($p = 1; $p -le $nper; $p++) { o ('<td>' + $vals[$p] + '</td>') }
  o '</tr>'
}

# "name 12 · name 9 · …" for one period, highest first
function TopInline([string]$cat, [int]$p, [int]$lim) {
  $m = $cnt[$cat][$p]
  $ord = SortDesc $m
  $parts = @()
  for ($i = 0; $i -lt $ord.Count -and $i -lt $lim; $i++) { $parts += '<b>' + (Hesc $ord[$i]) + '</b> ' + (Commas $m[$ord[$i]]) }
  if ($parts.Count -eq 0) { '–' } else { $parts -join ' · ' }
}

# q-quantile of a histogram holding `total` values; the middle of the bin it falls in
function HistPct($hist, [int]$maxb, [double]$total, [double]$q, [double]$width) {
  if ($null -eq $hist) { return 0 }
  $need = $total * $q; $run = 0.0
  for ($b = 0; $b -le $maxb; $b++) {
    $run += $hist[$b]
    if ($run -gt 0 -and $run -ge $need) { return ($b + 0.5) * $width }
  }
  0
}
# % of a period's calls whose context is at or above bin `from`
function ShareOver([int]$p, [int]$from) {
  $run = 0.0
  for ($b = $from; $b -le $CTX_MAXBIN; $b++) { $run += $CT_h[$p][$b] }
  if ($CT_n[$p] -gt 0) { $run / $CT_n[$p] * 100 } else { 0 }
}

$CSS = @'
:root{--bg:#f6f5f1;--card:#ffffff;--ink:#1d1c19;--muted:#6f6d66;--line:#e7e4dc;--soft:#f1efe9;
--p1:#5b6cf0;--p2:#e08a2e;--p3:#1f9e8a;--p4:#c2527a;--p5:#8b5cf6;--k1:#6c7cf5;--k2:#e3a33b;--k3:#2eaf8f;--k4:#b8b4aa;--good:#23915a}
@media (prefers-color-scheme:dark){:root:not([data-theme='light']){--bg:#131311;--card:#1c1c19;--ink:#ecebe5;--muted:#9c9a91;--line:#2d2c28;--soft:#24231f}}
:root[data-theme='dark']{--bg:#131311;--card:#1c1c19;--ink:#ecebe5;--muted:#9c9a91;--line:#2d2c28;--soft:#24231f}
:root{--ok:#1f8a52;--info:#2f6fd6;--bad:#d03b3b}@media (prefers-color-scheme:dark){:root:not([data-theme='light']){--ok:#4cc38a;--info:#6ea8ff;--bad:#ff6b6b}}:root[data-theme='dark']{--ok:#4cc38a;--info:#6ea8ff;--bad:#ff6b6b}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased}
.wrap{max-width:1160px;margin:0 auto;padding:40px 16px 72px}
h1{font-size:30px;letter-spacing:-.02em;margin:0 0 6px}h2{font-size:19px;letter-spacing:-.01em;margin:0 0 14px}
.sub{color:var(--muted);margin:0}.legend{display:flex;flex-wrap:wrap;gap:8px 18px;margin-top:14px;color:var(--muted);font-size:14px}
.chip{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:7px;vertical-align:0}
section{margin-top:40px}.grid{display:grid;gap:16px;grid-template-columns:repeat(auto-fit,minmax(280px,1fr))}.grid.one{grid-template-columns:1fr}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:18px 20px;min-width:0}
.kh{display:flex;align-items:center;gap:8px;font-weight:600}.kl{color:var(--muted);font-size:13px;margin:2px 0 12px}
.big{font-size:32px;font-weight:700;letter-spacing:-.02em;font-variant-numeric:tabular-nums}
.stats{display:grid;grid-template-columns:1fr 1fr;gap:10px 16px;margin-top:12px}.stats div{font-size:13px;color:var(--muted)}.stats b{display:block;font-size:16px;color:var(--ink);font-variant-numeric:tabular-nums}
.tw{overflow-x:auto}table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums;font-size:14px}
th,td{padding:9px 10px;border-bottom:1px solid var(--line);text-align:right;white-space:nowrap}th{color:var(--muted);font-weight:600;font-size:13px}
th:first-child,td:first-child{text-align:left}tr.sub td:first-child{padding-left:28px;color:var(--muted)}tr.tot td{font-weight:700}
td.list{text-align:left;white-space:normal;min-width:130px;font-size:13px;color:var(--muted)}td.list b{color:var(--ink);font-weight:600}
.stack{display:flex;height:24px;border-radius:8px;overflow:hidden;background:var(--soft)}.stack span{display:flex;align-items:center;justify-content:center;height:100%;font-size:11px;font-weight:600;white-space:nowrap;overflow:hidden}.cap{margin:-2px 0 10px 80px;font-size:12px;color:var(--muted);font-variant-numeric:tabular-nums}
.row{display:grid;grid-template-columns:68px 1fr 84px;gap:12px;align-items:center;margin:6px 0;font-size:13px;font-variant-numeric:tabular-nums}.row .v{text-align:right}
.top{list-style:none;margin:0;padding:0}.top li{padding:8px 0;border-bottom:1px solid var(--line)}.top li:last-child{border-bottom:0}
.top .name{display:flex;justify-content:space-between;gap:10px;font-size:14px}.top .name span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.top .name b{font-variant-numeric:tabular-nums}.bars{margin-top:5px;display:grid;gap:3px}
.bar{display:grid;grid-template-columns:1fr 72px;gap:8px;align-items:center;font-size:12px;color:var(--muted);font-variant-numeric:tabular-nums}
.bar i{display:block;height:6px;border-radius:3px}.bar em{font-style:normal;text-align:right}
.keys{display:flex;flex-wrap:wrap;gap:6px 16px;font-size:13px;color:var(--muted);margin-bottom:12px}
.note{color:var(--muted);font-size:14px}.note li{margin:6px 0}
.grid.cards{grid-template-columns:repeat(auto-fit,minmax(200px,1fr))}.grid.cards .big{font-size:28px}.grid.cards .stats{gap:8px 12px}
.chartwrap{overflow-x:auto}.chart{display:block;width:100%;min-width:640px;height:auto}.chart text{fill:var(--muted);font-size:12px;font-family:inherit}
.chart .gl{stroke:var(--line)}.chart .ln{fill:none;stroke:var(--ink);stroke-width:2;opacity:.75}.chart .dot{fill:var(--card);stroke:var(--ink);stroke-width:1.5;opacity:.85}.chart .hit{fill:transparent}.chart .hit:hover{fill:var(--soft);opacity:.5}
.lk{display:inline-block;width:18px;height:0;border-top:2px solid var(--ink);opacity:.75;margin-right:7px;vertical-align:4px}
td small{display:block;color:var(--muted);font-size:12px;font-weight:400}td b{font-weight:650}
.tv{position:absolute;opacity:0;pointer-events:none}.tvl{display:inline-block;padding:7px 16px;border:1px solid var(--line);background:var(--card);color:var(--muted);cursor:pointer;font-size:14px;user-select:none}
.tvl.lm{border-radius:0;margin-left:-1px}.tvl.l1{border-radius:10px 0 0 10px}.tvl.l2{border-radius:0 10px 10px 0;margin-left:-1px}.tv:checked+.tvl{background:var(--ink);color:var(--bg);border-color:var(--ink)}.tv:focus-visible+.tvl{outline:2px solid var(--p1);outline-offset:2px}
.views{margin-top:16px}.views .by-item,.views .by-period{display:none}#tv1:checked~.views .by-item{display:grid}#tv2:checked~.views .by-period{display:block}
.pcard{margin-bottom:16px}.pgrid{display:grid;gap:18px 24px;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));margin-top:12px}
.pgrid h3{font-size:13px;color:var(--muted);font-weight:600;margin:0 0 6px;text-transform:uppercase;letter-spacing:.04em}
.mini{list-style:none;margin:0;padding:0}.mini li{padding:5px 0;font-size:13px}.mini .name{display:flex;justify-content:space-between;gap:8px}.mini .name span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.mini i{display:block;height:4px;border-radius:2px;margin-top:4px}
.top small.sh{color:var(--muted);font-weight:400;font-size:12px;margin-left:4px}.top small.tr{color:var(--muted);font-size:11px;margin-left:8px;font-weight:400}.top small.tr.new{color:var(--good);font-weight:600}
.sv{font-weight:600;cursor:help}.sv.g{color:var(--ok)}.sv.b{color:var(--info)}.sv.r{color:var(--bad)}
h3.ch{font-size:15px;margin:26px 0 4px}p.cd{margin:0 0 10px;max-width:900px}
summary{cursor:pointer;list-style:none;display:flex;align-items:center;gap:10px;font-size:19px;font-weight:700;letter-spacing:-.01em;margin:0 0 14px;user-select:none}summary::-webkit-details-marker{display:none}
summary::before{content:'';width:8px;height:8px;border-right:2px solid var(--muted);border-bottom:2px solid var(--muted);transform:rotate(-45deg);transition:transform .15s;flex:none}details[open]>summary::before{transform:rotate(45deg)}details:not([open])>summary{margin-bottom:0}summary:focus-visible{outline:2px solid var(--p1);outline-offset:4px;border-radius:4px}
'@

function Write-HtmlReport {
  o "<!doctype html><html lang='en'><head><meta charset='utf-8'>"
  o "<meta name='viewport' content='width=device-width,initial-scale=1'>"
  o '<title>Claude Code Usage</title>'
  o '<style>'
  o $CSS.TrimEnd()
  o "</style></head><body><div class='wrap'>"

  # --- Header ---
  o '<header><h1>Claude Code usage</h1>'
  $src = if ($loaded_live -gt 0) { "LiteLLM ($loaded_live models)" } else { 'a built-in list' }
  o ("<p class='sub'>Costs are estimates at public API prices, not your bill · prices from " + $src + ' · made ' + (Hesc $GEN_TIME) + '</p>')
  o "<div class='legend'>"
  for ($p = 1; $p -le $nper; $p++) {
    o ("<span><i class='chip' style='background:" + (PColor $p) + "'></i><b>" + (Hesc $plab[$p]) + '</b> · ' + (Hesc $plong[$p]) + '</span>')
  }
  o '</div></header>'

  # --- Period cards ---
  o "<section><div class='grid cards'>"
  for ($p = 1; $p -le $nper; $p++) {
    $tin = TinOf $p
    o ("<div class='card'><div class='kh'><i class='chip' style='background:" + (PColor $p) + "'></i>" + (Hesc $plab[$p]) + '</div>')
    o ("<div class='kl'>" + (Hesc $plong[$p]) + "</div><div class='big'>" + (Money $P_cost[$p]) + '</div>')
    o ("<div class='stats'><div>API calls<b>" + (Commas $P_calls[$p]) + '</b></div><div>Hit rate<b>' + (Pct $P_cr[$p] $tin) + '</b></div>')
    o ('<div>Input<b>' + (FmtTok $tin) + '</b></div><div>Output<b>' + (FmtTok $P_out[$p]) + '</b></div>')
    o ('<div>Tool calls<b>' + (Commas ($csum['tool'][$p] + $csum['mcp'][$p])) + '</b></div><div>No cache<b>' + (Money $P_nc[$p]) + '</b></div></div></div>')
  }
  o '</div></section>'

  # --- Comparison table ---
  $title = if ($nper -gt 1) { 'Comparison' } else { 'Summary' }
  o ('<section><details open><summary>' + $title + "</summary><p class='note cd'>The same numbers for each period, side by side. <b>Input</b> is everything sent to the model, which includes the whole conversation again on every call. The lines under it show how much of that input was cheap (read from cache) and how much was expensive (written to cache or not cached). Some numbers are colored: <span class='sv g'>green</span> is healthy, <span class='sv b'>blue</span> is worth a look, <span class='sv r'>red</span> means something is wrong. Hover a colored number to see why.</p><div class='card tw'><table><thead><tr><th></th>")
  PeriodHeads
  o '</tr></thead><tbody>'
  $v = New-Object string[] 7
  for ($p = 1; $p -le $nper; $p++) { $v[$p] = Commas $P_calls[$p] }; HRow 'API calls' $v ''
  for ($p = 1; $p -le $nper; $p++) { $v[$p] = FmtTok (TinOf $p) }; HRow 'Input tokens, total' $v ''
  for ($p = 1; $p -le $nper; $p++) { $v[$p] = (FmtTok $P_cr[$p]) + ' · ' + (Money $P_ccr[$p]) }; HRow 'Cache read (hit)' $v 'sub'
  for ($p = 1; $p -le $nper; $p++) { $v[$p] = FmtTok $P_cw5[$p] }; HRow 'Cache write, 5 min' $v 'sub'
  for ($p = 1; $p -le $nper; $p++) { $v[$p] = FmtTok $P_cw1h[$p] }; HRow 'Cache write, 1 hour' $v 'sub'
  for ($p = 1; $p -le $nper; $p++) {
    $sh = Pcts ($P_cw5[$p] + $P_cw1h[$p]) (TinOf $p)
    $v[$p] = Paint (LvlLo $sh 3 8) ((FmtTok ($P_cw5[$p] + $P_cw1h[$p])) + ' · ' + (Money $P_ccw[$p])) ((F $sh 'F1') + '% of input tokens were cache writes. Under 3% is healthy, over 8% needs attention.')
  }
  HRow 'Cache writes (miss)' $v 'sub'
  for ($p = 1; $p -le $nper; $p++) {
    $sh = Pcts $P_in[$p] (TinOf $p)
    $v[$p] = Paint (LvlLo $sh 0.5 2) ((FmtTok $P_in[$p]) + ' · ' + (Money $P_cin[$p])) ((F $sh 'F2') + '% of input tokens were not cached. Under 0.5% is healthy, over 2% needs attention.')
  }
  HRow 'Not cached (miss)' $v 'sub'
  for ($p = 1; $p -le $nper; $p++) {
    $sh = Pcts $P_cr[$p] (TinOf $p)
    $v[$p] = Paint (LvlHi $sh 95 90) (Pct $P_cr[$p] (TinOf $p)) ((F $sh 'F1') + '% of input tokens were cache reads. 95% or more is healthy, under 90% needs attention.')
  }
  HRow 'Cache hit rate' $v 'sub'
  for ($p = 1; $p -le $nper; $p++) { $v[$p] = (FmtTok $P_out[$p]) + ' · ' + (Money $P_cout[$p]) }; HRow 'Output tokens' $v ''
  for ($p = 1; $p -le $nper; $p++) {
    if ($p -gt 1 -and $pe[$p] -le $NOW -and $P_cost[$p - 1] -gt 0) {
      $sh = ($P_cost[$p] / $P_cost[$p - 1] - 1) * 100
      $v[$p] = Paint (LvlLo $sh 10.0001 30) (Money $P_cost[$p]) ((SignF $sh 0) + '% vs ' + $plab[$p - 1] + '. Flat, or up to 10%, is fine; up 10% to 30% is worth a look; up over 30% needs attention.')
    }
    else { $v[$p] = Money $P_cost[$p] }
  }
  HRow 'Est. API cost' $v 'tot'
  for ($p = 1; $p -le $nper; $p++) { $v[$p] = Money $P_nc[$p] }; HRow 'Cost with no cache' $v ''
  foreach ($cat in $hcats) {
    o ('<tr><td>Top ' + $cat_title[$cat].ToLowerInvariant() + '</td>')
    for ($p = 1; $p -le $nper; $p++) { o ("<td class='list'>" + (TopInline $cat $p 5) + '</td>') }
    o '</tr>'
  }
  o '</tbody></table></div></details></section>'

  # --- Where the money goes ---
  $kinds = @('', 'Cache read (hit) · good', 'Cache write (miss) · avoid', 'Output', 'Input, not cached · avoid')
  $kcol = @('', 'var(--k1)', 'var(--k2)', 'var(--k3)', 'var(--k4)')
  $kfg = @('', '#fff', '#1d1c19', '#fff', '#1d1c19')
  o "<section><details open><summary>Where the money goes</summary><div class='card'>"
  o "<p class='note' style='margin:0 0 12px'>Each bar splits that period's cost by what you paid for. <b>Cache read is the good part</b>: the model re-reads a conversation it already stored, at about a tenth of the normal price. <b>Cache write is the part to avoid</b>: it means storing the conversation again, at 1.25 to 2 times the normal price. <b>Input, not cached</b> is full price. <b>Output</b> is what the model wrote back. Under each bar, the same split in tokens shows how well the cache is working.</p><div class='keys'>"
  for ($j = 1; $j -le 4; $j++) { o ("<span><i class='chip' style='background:" + $kcol[$j] + "'></i>" + $kinds[$j] + '</span>') }
  o '</div>'
  for ($p = 1; $p -le $nper; $p++) {
    $kc = @(0, $P_ccr[$p], $P_ccw[$p], $P_cout[$p], $P_cin[$p])
    o ("<div class='row'><span>" + (Hesc $plab[$p]) + "</span><div class='stack'>")
    for ($j = 1; $j -le 4; $j++) {
      $w = if ($P_cost[$p] -gt 0) { $kc[$j] / $P_cost[$p] * 100 } else { 0 }
      if ($w -gt 0) {
        $lbl = if ($w -ge 6) { (F $w 'F0') + '%' } else { '' }
        o ("<span style='width:" + (F $w 'F2') + '%;background:' + $kcol[$j] + ';color:' + $kfg[$j] + "' title='" + $kinds[$j] + ': ' + (Money $kc[$j]) + ' (' + (F $w 'F1') + "% of cost)'>" + $lbl + '</span>')
      }
    }
    o ("</div><span class='v'>" + (Money $P_cost[$p]) + '</span></div>')
    $tin = TinOf $p
    o ("<div class='cap'>Of input tokens: <b>" + (Pct $P_cr[$p] $tin) + '</b> cache read · ' + (Pct ($P_cw5[$p] + $P_cw1h[$p]) $tin) + ' cache write · ' + (Pct $P_in[$p] $tin) + ' not cached</div>')
  }
  o '</div></details></section>'

  Write-Cache
  Write-Context
  Write-Models
  Write-Activity
  Write-Top

  # --- Notes ---
  o "<section><details open><summary>How to read this</summary><div class='card'><ul class='note' style='margin:0;padding-left:18px'>"
  o '<li><b>These costs are estimates.</b> They use public API prices, so they are not your Pro or Max bill, which is measured differently.</li>'
  o '<li><b>Three kinds of input.</b> <b>Cache read</b>: the model re-reads a conversation it already stored, at about a tenth of the normal price. <b>Cache write</b>: the model stores new content, for 5 minutes (1.25x the price) or 1 hour (2x). <b>Not cached</b>: normal price (1x). Output is never cached.</li>'
  o "<li><b>What makes the cost go up:</b> the number of calls, times the size of the conversation, times the model's price. Every tool call is one more call that re-reads the whole conversation.</li>"
  o ('<li><b>Each thing is counted once.</b> Some log lines are copies (from streamed replies, or from resumed and forked sessions). API responses go from ' + (Commas $raw_u) + ' log lines to ' + (Commas $uniq_u) + ' unique ones, tool and MCP calls from ' + (Commas $raw_t) + ' to ' + (Commas $uniq_t) + ', and slash commands from ' + (Commas $raw_c) + ' to ' + (Commas $uniq_c) + '. Each is counted at its earliest time. Days use your local time.</li>')
  o '</ul></div></details></section>'
  o '</div></body></html>'
}

# --- Cache: how much of the input was read from cache, against written or not cached ---
function Write-Cache {
  $kn = @('', 'Cache read (hit) · good', 'Cache write (miss) · avoid', 'Not cached · avoid')
  $kc = @('', 'var(--k1)', 'var(--k2)', 'var(--k4)')
  $kf = @('', '#fff', '#1d1c19', '#1d1c19')
  o "<section><details open><summary>Cache: read vs write</summary><div class='card'>"
  o "<p class='note' style='margin:0 0 12px'>The same spending, counted in <b>tokens</b> instead of dollars. Almost every token should be a <b>cache read</b>: the model is re-reading a conversation it already stored, which is cheap. A <b>cache write</b> means it had to store the conversation again, usually because you were idle for a while or changed the conversation. More reads and fewer writes means a lower bill.</p><div class='keys'>"
  for ($j = 1; $j -le 3; $j++) { o ("<span><i class='chip' style='background:" + $kc[$j] + "'></i>" + $kn[$j] + '</span>') }
  o '</div>'
  for ($p = 1; $p -le $nper; $p++) {
    $tin = TinOf $p
    if ($tin -le 0) { continue }
    $kv = @(0, $P_cr[$p], ($P_cw5[$p] + $P_cw1h[$p]), $P_in[$p])
    o ("<div class='row'><span>" + (Hesc $plab[$p]) + "</span><div class='stack'>")
    for ($j = 1; $j -le 3; $j++) {
      $w = $kv[$j] / $tin * 100
      if ($w -gt 0) {
        $lbl = if ($w -ge 6) { (F $w 'F0') + '%' } else { '' }
        o ("<span style='width:" + (F $w 'F2') + '%;background:' + $kc[$j] + ';color:' + $kf[$j] + "' title='" + $kn[$j] + ': ' + (FmtTok $kv[$j]) + ' tokens (' + (F $w 'F1') + "% of input)'>" + $lbl + '</span>')
      }
    }
    o ("</div><span class='v'>" + (FmtTok $tin) + '</span></div>')
    $ratio = if ($kv[2] -gt 0) { ' · <b>' + (F ($P_cr[$p] / $kv[2]) 'F0') + ' tokens read for every token written</b>' } else { '' }
    o ("<div class='cap'><b>" + (Pct $P_cr[$p] $tin) + '</b> cache read · ' + (Pct $kv[2] $tin) + ' cache write · ' + (Pct $P_in[$p] $tin) + ' not cached' + $ratio + '</div>')
  }
  # hit rate per bucket
  $bk = SortKeys $B_in
  $nb = $bk.Count
  $rmin = 100.0
  foreach ($k in $bk) { if ($B_in[$k] -gt 0) { $r = $B_cr[$k] / $B_in[$k] * 100; if ($r -lt $rmin) { $rmin = $r } } }
  if ($nb -ge 2) {
    $ymin = 80                                  # hit rates sit near the top, so start at 80% (lower only if the data does)
    if ($rmin -lt 80) { $ymin = [math]::Truncate(($rmin - 1) / 5) * 5 }
    if ($ymin -lt 0) { $ymin = 0 }
    $gW = 1100; $gH = 300; $gL = 70; $gR = 24; $gT = 16; $gB = 44
    $pw = $gW - $gL - $gR; $ph = $gH - $gT - $gB; $slot = $pw / $nb
    $uw = UnitWord $bucket_unit
    o ("<h3 class='ch'>How well did the cache hold up each " + $uw + '?</h3>')
    o ("<p class='note cd'>The <b>cache hit rate</b> is the share of tokens that were read from cache. Higher is better. A dip means the stored conversation had gone cold (you were idle for a while, started a new session or cleared the chat), so it had to be stored again at a higher price. The axis starts at " + $ymin + '%, not at zero, so small dips are easy to see. The colors match the numbers in the table: green is 95% or more, blue is 90% to 95%, red is under 90%.</p>')
    o ("<div class='chartwrap'><svg class='chart' viewBox='0 0 $gW $gH' role='img' aria-label='Cache hit rate per " + $uw + "'>")
    for ($g = 0; $g -le 4; $g++) {
      $y = $gT + $ph - $ph * $g / 4
      o ("<line class='gl' x1='$gL' x2='" + ($gW - $gR) + "' y1='" + (F $y 'F1') + "' y2='" + (F $y 'F1') + "'/>")
      o ("<text x='" + ($gL - 10) + "' y='" + (F ($y + 4) 'F1') + "' text-anchor='end'>" + (G ($ymin + (100 - $ymin) * $g / 4)) + '%</text>')
    }
    # colored bands match the status marks: 95%+ healthy, 90 to 95% worth a look, under 90% needs attention
    for ($g = 1; $g -le 3; $g++) {
      $lo = @(0, $ymin, 90, 95)[$g]
      $hi = @(0, 90, 95, 100)[$g]
      if ($lo -lt $ymin) { $lo = $ymin }
      if ($hi -le $ymin) { continue }
      $fill = @('', '#d64545', '#3b82f6', '#23915a')[$g]
      o ("<rect x='$gL' width='$pw' y='" + (F ($gT + $ph - ($hi - $ymin) / (100 - $ymin) * $ph) 'F1') + "' height='" + (F (($hi - $lo) / (100 - $ymin) * $ph) 'F1') + "' fill='" + $fill + "' opacity='.09'/>")
    }
    $pts = ''
    for ($i = 1; $i -le $nb; $i++) {
      $k = $bk[$i - 1]
      if ($B_in[$k] -le 0) { continue }
      $r = $B_cr[$k] / $B_in[$k] * 100
      $x = $gL + $slot * ($i - 0.5); $y = $gT + $ph - ($r - $ymin) / (100 - $ymin) * $ph
      $pts += (F $x 'F1') + ',' + (F $y 'F1') + ' '
      $tip = (BucketLabel $k $bucket_unit) + ': ' + (F $r 'F1') + '% hit rate · ' + (FmtTok $B_cr[$k]) + ' of ' + (FmtTok $B_in[$k]) + ' input tokens read from cache'
      $dot = if ($nb -le 60) { "<circle class='dot' cx='" + (F $x 'F1') + "' cy='" + (F $y 'F1') + "' r='3'/>" } else { '' }
      o ('<g><title>' + (Hesc $tip) + "</title><rect class='hit' x='" + (F ($gL + $slot * ($i - 1)) 'F1') + "' y='$gT' width='" + (F $slot 'F2') + "' height='$ph'/>" + $dot + '</g>')
    }
    o ("<polyline class='ln' style='stroke:var(--p1)' points='" + $pts + "'/>")
    $step = [math]::Max(1, [math]::Truncate(($nb + 11) / 12))
    for ($i = 1; $i -le $nb; $i += $step) {
      o ("<text x='" + (F ($gL + $slot * ($i - 0.5)) 'F1') + "' y='" + ($gH - $gB + 22) + "' text-anchor='middle'>" + (Hesc (BucketTick $bk[$i - 1] $bucket_unit)) + '</text>')
    }
    o '</svg></div>'
  }
  o '</div></details></section>'
}

# --- Cost chart: bars = cost (left axis, stacked by period), line = API calls (right axis) ---
function Write-Chart {
  $bk = SortKeys $B_cost
  $nb = $bk.Count
  if ($nb -eq 0) { return }
  $maxc = 0.0; $maxn = 0.0
  foreach ($k in $bk) {
    if ($B_cost[$k] -gt $maxc) { $maxc = $B_cost[$k] }
    if ([double]$B_calls[$k] -gt $maxn) { $maxn = [double]$B_calls[$k] }
  }
  $yc = NiceMax $maxc; $yn = NiceMax $maxn
  $gW = 1100; $gH = 360; $gL = 70; $gR = 64; $gT = 16; $gB = 44
  $pw = $gW - $gL - $gR; $ph = $gH - $gT - $gB
  $slot = $pw / $nb; $bw = $slot * 0.7
  if ($bw -lt 1) { $bw = 1 }
  $uw = UnitWord $bucket_unit
  o ("<h3 class='ch'>Cost and requests per " + $uw + "</h3><p class='note cd'>The bars show what each " + $uw + ' cost (left scale). The line shows how many API calls (requests) you made (right scale). Cost usually goes up and down with the number of requests.</p>' + "<div class='keys'>")
  if ($nper -gt 1) { PeriodKeys } else { o ("<span><i class='chip' style='background:" + (PColor 1) + "'></i>Cost (left axis)</span>") }
  o "<span><i class='lk'></i>API calls (right axis)</span></div><div class='chartwrap'>"
  o ("<svg class='chart' viewBox='0 0 $gW $gH' role='img' aria-label='Cost and API calls per " + $uw + "'>")
  for ($g = 0; $g -le 4; $g++) {
    $y = $gT + $ph - $ph * $g / 4
    o ("<line class='gl' x1='$gL' x2='" + ($gW - $gR) + "' y1='" + (F $y 'F1') + "' y2='" + (F $y 'F1') + "'/>")
    o ("<text x='" + ($gL - 10) + "' y='" + (F ($y + 4) 'F1') + "' text-anchor='end'>" + (Money ($yc * $g / 4)) + '</text>')
    o ("<text x='" + ($gW - $gR + 10) + "' y='" + (F ($y + 4) 'F1') + "'>" + (FmtTok ($yn * $g / 4)) + '</text>')
  }
  $pts = ''
  for ($i = 1; $i -le $nb; $i++) {
    $k = $bk[$i - 1]
    $x = $gL + $slot * ($i - 1) + ($slot - $bw) / 2
    $tip = (BucketLabel $k $bucket_unit) + ': ' + (Money $B_cost[$k]) + ' · ' + (Commas $B_calls[$k]) + ' calls'
    o ('<g><title>' + (Hesc $tip) + "</title><rect class='hit' x='" + (F ($gL + $slot * ($i - 1)) 'F1') + "' y='$gT' width='" + (F $slot 'F2') + "' height='$ph'/>")
    $y = $gT + $ph
    $arr = $B_cost_p[$k]
    for ($p = 1; $p -le $nper; $p++) {
      $c = if ($null -ne $arr) { $arr[$p] } else { 0 }
      if ($c -le 0) { continue }
      $hgt = $c / $yc * $ph
      $y -= $hgt
      $rx = if ($bw -gt 6) { 2 } else { 0 }
      o ("<rect x='" + (F $x 'F1') + "' y='" + (F $y 'F1') + "' width='" + (F $bw 'F2') + "' height='" + (F $hgt 'F2') + "' rx='$rx' fill='" + (PColor $p) + "'/>")
    }
    o '</g>'
    $pts += (F ($gL + $slot * ($i - 0.5)) 'F1') + ',' + (F ($gT + $ph - [double]$B_calls[$k] / $yn * $ph) 'F1') + ' '
  }
  o ("<polyline class='ln' points='" + $pts + "'/>")
  if ($nb -le 60) {
    for ($i = 1; $i -le $nb; $i++) {
      $k = $bk[$i - 1]
      o ("<circle class='dot' cx='" + (F ($gL + $slot * ($i - 0.5)) 'F1') + "' cy='" + (F ($gT + $ph - [double]$B_calls[$k] / $yn * $ph) 'F1') + "' r='3'><title>" + (Hesc ((BucketLabel $k $bucket_unit) + ': ' + (Commas $B_calls[$k]) + ' calls')) + '</title></circle>')
    }
  }
  # about 12-16 ticks; hourly ticks sit on round hours so each midnight shows its date
  if ($bucket_unit -eq 'hour') {
    $step = 24
    foreach ($hs in 1, 2, 3, 6, 12, 24) { $step = $hs; if ($nb / $step -le 16) { break } }
    for ($i = 1; $i -le $nb; $i++) {
      if ([int]$bk[$i - 1].Substring(11, 2) % $step -eq 0) {
        o ("<text x='" + (F ($gL + $slot * ($i - 0.5)) 'F1') + "' y='" + ($gH - $gB + 22) + "' text-anchor='middle'>" + (Hesc (BucketTick $bk[$i - 1] $bucket_unit)) + '</text>')
      }
    }
  }
  else {
    $step = [math]::Max(1, [math]::Truncate(($nb + 11) / 12))
    for ($i = 1; $i -le $nb; $i += $step) {
      o ("<text x='" + (F ($gL + $slot * ($i - 0.5)) 'F1') + "' y='" + ($gH - $gB + 22) + "' text-anchor='middle'>" + (Hesc (BucketTick $bk[$i - 1] $bucket_unit)) + '</text>')
    }
  }
  o '</svg></div>'
}

# Line chart, one line per period. $LY[p][i] = y in %, $LXL[i] = label of point i, n points, an axis label every tk points.
function LineChart([string]$title, [string]$desc, [string]$xtitle, [string]$ytitle, [int]$n, [int]$tk) {
  $ymax = 0.0; $cntp = 0
  for ($p = 1; $p -le $nper; $p++) { if ($LOK[$p]) { $cntp++; for ($i = 1; $i -le $n; $i++) { if ($LY[$p][$i] -gt $ymax) { $ymax = $LY[$p][$i] } } } }
  if ($cntp -eq 0 -or $ymax -le 0) { return }
  $ymax = NiceMax $ymax
  $gW = 1100; $gH = 320; $gL = 70; $gR = 24; $gT = 16; $gB = 50
  $pw = $gW - $gL - $gR; $ph = $gH - $gT - $gB; $hw = $pw / ($n - 1)
  o ("<h3 class='ch'>" + (Hesc $title) + "</h3><p class='note cd'>" + $desc + '</p>')
  if ($nper -gt 1) {
    o "<div class='keys'>"
    for ($p = 1; $p -le $nper; $p++) { if ($LOK[$p]) { o ("<span><i class='chip' style='background:" + (PColor $p) + "'></i>" + (Hesc $plab[$p]) + '</span>') } }
    o '</div>'
  }
  o ("<div class='chartwrap'><svg class='chart' viewBox='0 0 $gW $gH' role='img' aria-label='" + (Hesc $title) + "'>")
  for ($g = 0; $g -le 4; $g++) {
    $y = $gT + $ph - $ph * $g / 4
    o ("<line class='gl' x1='$gL' x2='" + ($gW - $gR) + "' y1='" + (F $y 'F1') + "' y2='" + (F $y 'F1') + "'/>")
    o ("<text x='" + ($gL - 10) + "' y='" + (F ($y + 4) 'F1') + "' text-anchor='end'>" + (G ($ymax * $g / 4)) + '%</text>')
  }
  for ($i = 1; $i -le $n; $i += $tk) {
    o ("<text x='" + (F ($gL + $hw * ($i - 1)) 'F1') + "' y='" + ($gH - $gB + 20) + "' text-anchor='middle'>" + $LXL[$i] + '</text>')
  }
  o ("<text x='" + ($gL + $pw / 2) + "' y='" + ($gH - 8) + "' text-anchor='middle'>" + $xtitle + '</text>')
  o ("<text x='14' y='" + ($gT + $ph / 2) + "' text-anchor='middle' transform='rotate(-90 14 " + ($gT + $ph / 2) + ")'>" + $ytitle + '</text>')
  for ($p = 1; $p -le $nper; $p++) {
    if (-not $LOK[$p]) { continue }
    $pts = ''
    for ($i = 1; $i -le $n; $i++) { $pts += (F ($gL + $hw * ($i - 1)) 'F1') + ',' + (F ($gT + $ph - $LY[$p][$i] / $ymax * $ph) 'F1') + ' ' }
    o ("<polyline class='ln' style='stroke:" + (PColor $p) + "' points='" + $pts + "'/>")
    if ($n -le 25) {
      for ($i = 1; $i -le $n; $i++) {
        o ("<circle cx='" + (F ($gL + $hw * ($i - 1)) 'F1') + "' cy='" + (F ($gT + $ph - $LY[$p][$i] / $ymax * $ph) 'F1') + "' r='3' fill='" + (PColor $p) + "'/>")
      }
    }
  }
  for ($i = 1; $i -le $n; $i++) {
    $tip = $LXL[$i] + ':'
    for ($p = 1; $p -le $nper; $p++) {
      if ($LOK[$p]) {
        $pl = if ($nper -gt 1) { $plab[$p] + ' ' } else { '' }
        $sep = if ($p -lt $nper) { ' ·' } else { '' }
        $tip += ' ' + $pl + (F $LY[$p][$i] 'F1') + '%' + $sep
      }
    }
    o ('<g><title>' + (Hesc $tip) + "</title><rect class='hit' x='" + (F ($gL + $hw * ($i - 1) - $hw / 2) 'F1') + "' y='$gT' width='" + (F $hw 'F2') + "' height='$ph'/></g>")
  }
  o '</svg></div>'
}

function Write-Context {
  o "<section><details open><summary>Context size</summary><div class='card'>"
  o "<p class='note' style='margin:0 0 14px'>Each time Claude answers, it reads the whole conversation so far. The size of that conversation, in tokens, is the <b>context</b>. A bigger context makes every call cost more. This is counted for every API call, not for every message you type, because one message can make Claude call the API many times (for example to use tools). Only your main conversation is counted; helper agents (subagents) get their own row.</p>"
  # per-period table
  o "<div class='tw'><table><thead><tr><th></th>"
  PeriodHeads
  o '</tr></thead><tbody>'
  $v = New-Object string[] 7
  for ($p = 1; $p -le $nper; $p++) { $v[$p] = Commas $CT_n[$p] }; HRow 'Main-thread API calls' $v ''
  for ($p = 1; $p -le $nper; $p++) {
    if ($CT_n[$p] -gt 0) {
      $sh = ShareOver $p 40
      $v[$p] = Paint (LvlLo $sh 25 50) (FmtTok ($CT_sum[$p] / $CT_n[$p])) ((F $sh 'F0') + '% of calls had over 200k tokens of context. Under 25% is healthy, over 50% needs attention (bigger conversations cost more on every call).')
    }
    else { $v[$p] = '–' }
  }
  HRow 'Context per call, average' $v 'tot'
  for ($p = 1; $p -le $nper; $p++) { $v[$p] = if ($CT_n[$p] -gt 0) { FmtTok (HistPct $CT_h[$p] $CTX_MAXBIN $CT_n[$p] 0.5 $CTX_BIN) } else { '–' } }; HRow 'Median (50th percentile)' $v 'sub'
  for ($p = 1; $p -le $nper; $p++) { $v[$p] = if ($CT_n[$p] -gt 0) { FmtTok (HistPct $CT_h[$p] $CTX_MAXBIN $CT_n[$p] 0.95 $CTX_BIN) } else { '–' } }; HRow '95th percentile' $v 'sub'
  for ($p = 1; $p -le $nper; $p++) { $v[$p] = if ($CT_n[$p] -gt 0) { FmtTok $CT_max[$p] } else { '–' } }; HRow 'Largest' $v 'sub'
  for ($p = 1; $p -le $nper; $p++) { $v[$p] = Commas $SS_n[$p] }; HRow 'Sessions' $v ''
  for ($p = 1; $p -le $nper; $p++) { $v[$p] = if ($SS_n[$p] -gt 0) { F ($SS_calls_sum[$p] / $SS_n[$p]) 'F0' } else { '–' } }; HRow 'API calls per session, average' $v 'sub'
  for ($p = 1; $p -le $nper; $p++) { $v[$p] = if ($SS_n[$p] -gt 0) { F ((HistPct $SS_calls_h[$p] $CALL_CAP $SS_n[$p] 0.5 1) - 0.5) 'F0' } else { '–' } }; HRow 'Median' $v 'sub'
  for ($p = 1; $p -le $nper; $p++) { $v[$p] = if ($SS_n[$p] -gt 0) { F ((HistPct $SS_calls_h[$p] $CALL_CAP $SS_n[$p] 0.95 1) - 0.5) 'F0' } else { '–' } }; HRow '95th percentile' $v 'sub'
  for ($p = 1; $p -le $nper; $p++) { $v[$p] = if ($SS_n[$p] -gt 0) { FmtTok ($SS_pk_sum[$p] / $SS_n[$p]) } else { '–' } }; HRow 'Peak context per session, average' $v ''
  for ($p = 1; $p -le $nper; $p++) { $v[$p] = if ($SS_n[$p] -gt 0) { FmtTok (HistPct $SS_pk_h[$p] $CTX_MAXBIN $SS_n[$p] 0.5 $CTX_BIN) } else { '–' } }; HRow 'Median' $v 'sub'
  for ($p = 1; $p -le $nper; $p++) { $v[$p] = if ($SS_n[$p] -gt 0) { FmtTok (HistPct $SS_pk_h[$p] $CTX_MAXBIN $SS_n[$p] 0.95 $CTX_BIN) } else { '–' } }; HRow '95th percentile' $v 'sub'
  for ($p = 1; $p -le $nper; $p++) {
    $v[$p] = if ($SA_n[$p] -gt 0) { (Commas $SA_n[$p]) + ' calls · avg ' + (FmtTok ($SA_sum[$p] / $SA_n[$p])) + ' · p95 ' + (FmtTok (HistPct $SA_h[$p] $CTX_MAXBIN $SA_n[$p] 0.95 $CTX_BIN)) } else { '–' }
  }
  HRow 'Subagent calls' $v ''
  o '</tbody></table></div>'

  # 1. How many calls are over a given size: share of calls at or above each size
  $script:LOK = New-Object bool[] 7; $script:LY = New-Object object[] 7
  for ($p = 1; $p -le $nper; $p++) {
    $series = New-Object double[] 60; $run = 0.0
    $LOK[$p] = $CT_n[$p] -gt 0
    for ($b = $CTX_MAXBIN; $b -ge 0; $b--) {
      $run += $CT_h[$p][$b]
      if ($b % 5 -eq 0) { $series[$b / 5 + 1] = if ($CT_n[$p] -gt 0) { $run / $CT_n[$p] * 100 } else { 0 } }
    }
    $LY[$p] = $series
  }
  $script:LXL = New-Object string[] 42
  for ($i = 1; $i -le 41; $i++) { $LXL[$i] = KFmt (($i - 1) * 25000) }
  LineChart 'How many calls go over a given size?' 'Pick a size on the bottom axis. The line shows what <b>% of calls</b> had a bigger conversation than that. It starts at 100% and only goes down. If the line stays high toward the right, many of your calls ran with a very large conversation, which costs more.' 'Context size (tokens)' '% of calls above this size' 41 4

  # 2. Peak context per session: share of sessions whose peak reached at least each size.
  # Cumulative, so it stays a smooth falling line even when a week has only a few sessions.
  $script:LOK = New-Object bool[] 7; $script:LY = New-Object object[] 7
  for ($p = 1; $p -le $nper; $p++) {
    $series = New-Object double[] 60; $run = 0.0
    $LOK[$p] = $SS_n[$p] -gt 0
    for ($b = $CTX_MAXBIN; $b -ge 0; $b--) {
      $run += $SS_pk_h[$p][$b]
      if ($b % 5 -eq 0) { $series[$b / 5 + 1] = if ($SS_n[$p] -gt 0) { $run / $SS_n[$p] * 100 } else { 0 } }
    }
    $LY[$p] = $series
  }
  LineChart "How large does a session's context get?" 'A session grows until it ends. Its <b>peak</b> is the biggest conversation it reached. Pick a size on the bottom axis: the line shows what <b>% of sessions</b> got at least that big. If the line stays high toward 1M, many sessions grew until they hit the limit.' 'Context size (tokens)' '% of sessions that reached it' 41 4

  # 3. Session length: share of sessions with more than N API calls (cumulative, like the two above)
  $script:LOK = New-Object bool[] 7; $script:LY = New-Object object[] 7
  for ($p = 1; $p -le $nper; $p++) {
    $series = New-Object double[] 25; $run = 0.0
    $LOK[$p] = $SS_n[$p] -gt 0
    for ($b = $CALL_CAP; $b -ge 1; $b--) {
      $run += $SS_calls_h[$p][$b]
      # sessions with more than b-1 calls
      if ($b % 50 -eq 1 -and $b -le 1001) { $series[($b - 1) / 50 + 1] = if ($SS_n[$p] -gt 0) { $run / $SS_n[$p] * 100 } else { 0 } }
    }
    $series[1] = if ($SS_n[$p] -gt 0) { 100 } else { 0 }
    $LY[$p] = $series
  }
  $script:LXL = New-Object string[] 22
  for ($i = 1; $i -le 21; $i++) { $LXL[$i] = [string](($i - 1) * 50) }
  LineChart 'How long are your sessions?' 'Pick a number of calls on the bottom axis. The line shows what <b>% of sessions</b> lasted longer than that. Short sessions are cheap. Long sessions get more expensive, because the conversation keeps growing and is re-read on every call.' 'API calls in the session' '% of sessions longer than this' 21 2

  # 4. Context by call number in the session
  if ($ix_max -ge 2) {
    $gW = 1100; $gH = 340; $gL = 70; $gR = 24; $gT = 16; $gB = 44
    $pw = $gW - $gL - $gR; $ph = $gH - $gT - $gB
    $ymax = 0.0
    for ($i = 1; $i -le $ix_max; $i++) {
      $x = HistPct $IX_h[$i] $CTX_MAXBIN $IX_n[$i] 0.95 $CTX_BIN
      if ($x -gt $ymax) { $ymax = $x }
      if ($IX_sum[$i] / $IX_n[$i] -gt $ymax) { $ymax = $IX_sum[$i] / $IX_n[$i] }
    }
    $ymax = NiceMax $ymax
    $slot = $pw / $ix_max
    o "<h3 class='ch'>How does context grow as a session goes on?</h3>"
    o "<p class='note cd'>This shows how the conversation grows during a session. At call number N (bottom axis), the lines show how big the conversation was: on <b>average</b>, for the <b>median</b> session (half of sessions are smaller), and for a big one, the <b>95th percentile</b> (only 1 session in 20 is bigger). The dotted line marks 200k tokens. A steep line means the conversation fills up fast.</p>"
    o ("<div class='keys'><span><i class='lk' style='border-color:var(--p1)'></i>Average</span><span><i class='lk' style='border-color:var(--p3);border-top-style:dashed'></i>Median</span><span><i class='lk' style='border-color:var(--p2)'></i>95th percentile</span><span>A point needs at least " + $CTX_MINSESS + ' sessions that reach that call</span></div>')
    o "<div class='chartwrap'><svg class='chart' viewBox='0 0 $gW $gH' role='img' aria-label='Context size by call number in the session'>"
    for ($g = 0; $g -le 4; $g++) {
      $y = $gT + $ph - $ph * $g / 4
      o ("<line class='gl' x1='$gL' x2='" + ($gW - $gR) + "' y1='" + (F $y 'F1') + "' y2='" + (F $y 'F1') + "'/>")
      o ("<text x='" + ($gL - 10) + "' y='" + (F ($y + 4) 'F1') + "' text-anchor='end'>" + (FmtTok ($ymax * $g / 4)) + '</text>')
    }
    if (200000 -lt $ymax) {
      $y = $gT + $ph - 200000 / $ymax * $ph
      o ("<line x1='$gL' x2='" + ($gW - $gR) + "' y1='" + (F $y 'F1') + "' y2='" + (F $y 'F1') + "' stroke='var(--muted)' stroke-dasharray='2 4'/><text x='" + ($gW - $gR) + "' y='" + (F ($y - 5) 'F1') + "' text-anchor='end'>200k</text>")
    }
    $ptsA = ''; $ptsM = ''; $ptsP = ''
    for ($i = 1; $i -le $ix_max; $i++) {
      $x = $gL + $slot * ($i - 0.5)
      $va = $IX_sum[$i] / $IX_n[$i]
      $vm = HistPct $IX_h[$i] $CTX_MAXBIN $IX_n[$i] 0.5 $CTX_BIN
      $vp = HistPct $IX_h[$i] $CTX_MAXBIN $IX_n[$i] 0.95 $CTX_BIN
      $ptsA += (F $x 'F1') + ',' + (F ($gT + $ph - $va / $ymax * $ph) 'F1') + ' '
      $ptsM += (F $x 'F1') + ',' + (F ($gT + $ph - $vm / $ymax * $ph) 'F1') + ' '
      $ptsP += (F $x 'F1') + ',' + (F ($gT + $ph - $vp / $ymax * $ph) 'F1') + ' '
      $tip = "Call ${i}: average " + (FmtTok $va) + ' · median ' + (FmtTok $vm) + ' · p95 ' + (FmtTok $vp) + ' · ' + (Commas $IX_n[$i]) + ' sessions'
      o ('<g><title>' + (Hesc $tip) + "</title><rect class='hit' x='" + (F ($gL + $slot * ($i - 1)) 'F1') + "' y='$gT' width='" + (F $slot 'F2') + "' height='$ph'/></g>")
    }
    o ("<polyline class='ln' style='stroke:var(--p2)' points='" + $ptsP + "'/>")
    o ("<polyline class='ln' style='stroke:var(--p3);stroke-dasharray:5 4' points='" + $ptsM + "'/>")
    o ("<polyline class='ln' style='stroke:var(--p1)' points='" + $ptsA + "'/>")
    $step = if ($ix_max -le 20) { 1 } elseif ($ix_max -le 60) { 5 } elseif ($ix_max -le 160) { 10 } elseif ($ix_max -le 300) { 25 } else { 50 }
    for ($i = $step; $i -le $ix_max; $i += $step) {
      o ("<text x='" + (F ($gL + $slot * ($i - 0.5)) 'F1') + "' y='" + ($gH - $gB + 22) + "' text-anchor='middle'>" + $i + '</text>')
    }
    o ("<text x='" + ($gL + $pw / 2) + "' y='" + ($gH - 6) + "' text-anchor='middle'>API call number in the session</text>")
    o '</svg></div>'
  }

  # 5. Share of calls by context size band
  $kname = @('', 'Under 50k', '50k to 100k', '100k to 200k', '200k to 500k', 'Over 500k')
  $kcol = @('', 'var(--k3)', 'var(--k1)', 'var(--k2)', 'var(--p2)', 'var(--p4)')
  $kfg = @('', '#fff', '#fff', '#1d1c19', '#1d1c19', '#fff')
  o "<h3 class='ch'>Where do your calls land?</h3><p class='note cd'>The same calls as the first chart, put into five size groups. Each bar is 100% of the calls in that period. The more orange and pink, the more calls ran with a conversation over 200k tokens.</p><div class='keys'>"
  for ($j = 1; $j -le 5; $j++) { o ("<span><i class='chip' style='background:" + $kcol[$j] + "'></i>" + $kname[$j] + '</span>') }
  o '</div>'
  $bins = @(0, 0, 10, 20, 40, 100, 100000)   # bin edges in units of CTX_BIN: 0, 50k, 100k, 200k, 500k, end
  for ($p = 1; $p -le $nper; $p++) {
    if ($CT_n[$p] -eq 0) { continue }
    o ("<div class='row'><span>" + (Hesc $plab[$p]) + "</span><div class='stack'>")
    for ($j = 1; $j -le 5; $j++) {
      $lo = $bins[$j]; $hi = $bins[$j + 1]
      $tot = 0.0
      for ($i = $lo; $i -lt $hi -and $i -le $CTX_MAXBIN; $i++) { $tot += $CT_h[$p][$i] }
      $share = $tot / $CT_n[$p] * 100
      if ($share -gt 0) {
        $lbl = if ($share -ge 6) { (F $share 'F0') + '%' } else { '' }
        o ("<span style='width:" + (F $share 'F2') + '%;background:' + $kcol[$j] + ';color:' + $kfg[$j] + "' title='" + $kname[$j] + ': ' + (F $share 'F1') + "% of calls'>" + $lbl + '</span>')
      }
    }
    o ("</div><span class='v'>" + (Commas $CT_n[$p]) + ' calls</span></div>')
  }
  o '</div></details></section>'
}

# --- Cost by model: one bar per period, one segment per model ---
function Write-ModelChart {
  $ord = SortDesc $mod_cost
  $n = $ord.Count
  if ($n -eq 0) { return }
  $mc = @('', '#5b6cf0', '#e08a2e', '#1f9e8a', '#c2527a', '#8b5cf6', '#3b82f6', '#d4a72c', '#b8b4aa')
  $fg = @('', '#fff', '#1d1c19', '#fff', '#fff', '#fff', '#fff', '#1d1c19', '#1d1c19')
  $nm = [math]::Min($n, 7)
  o "<div class='card' style='margin-bottom:16px'><div class='keys'>"
  for ($i = 1; $i -le $nm; $i++) { o ("<span><i class='chip' style='background:" + $mc[$i] + "'></i>" + (Hesc $ord[$i - 1]) + '</span>') }
  if ($n -gt $nm) { o ("<span><i class='chip' style='background:" + $mc[8] + "'></i>Other (" + ($n - $nm) + ')</span>') }
  o '</div>'
  for ($p = 1; $p -le $nper; $p++) {
    if ($P_cost[$p] -le 0) { continue }
    o ("<div class='row'><span>" + (Hesc $plab[$p]) + "</span><div class='stack'>")
    $other = 0.0
    for ($i = 1; $i -le $n; $i++) {
      $c = [double]$PM_cost[$p][$ord[$i - 1]]
      if ($i -gt $nm) { $other += $c; continue }
      $w = $c / $P_cost[$p] * 100
      if ($w -gt 0) {
        $lbl = if ($w -ge 6) { (F $w 'F0') + '%' } else { '' }
        o ("<span style='width:" + (F $w 'F2') + '%;background:' + $mc[$i] + ';color:' + $fg[$i] + "' title='" + (Hesc $ord[$i - 1]) + ': ' + (Money $c) + ' (' + (F $w 'F1') + "% of cost)'>" + $lbl + '</span>')
      }
    }
    if ($other -gt 0) {
      $w = $other / $P_cost[$p] * 100
      $lbl = if ($w -ge 6) { (F $w 'F0') + '%' } else { '' }
      o ("<span style='width:" + (F $w 'F2') + '%;background:' + $mc[8] + ';color:' + $fg[8] + "' title='Other models: " + (Money $other) + ' (' + (F $w 'F1') + "% of cost)'>" + $lbl + '</span>')
    }
    o ("</div><span class='v'>" + (Money $P_cost[$p]) + '</span></div>')
  }
  o '</div>'
}

# --- Models: one row per model, one column per period ---
function Write-Models {
  $ord = SortDesc $mod_cost
  o "<section><details open><summary>Models</summary><p class='note cd'>Which models your money went to. Each bar is 100% of that period's cost, so a shift between colors from one period to the next shows a change in which model you lean on. A pricier model (such as Opus) costs more for the same work than a cheaper one (such as Sonnet or Haiku). The table below gives the dollars and calls for each model. A model name in red has no known price, so it was costed at a default price.</p>"
  Write-ModelChart
  o "<div class='card tw'><table><thead><tr><th>Model</th>"
  PeriodHeads
  if ($nper -gt 1) { o '<th>Total</th>' }
  o '</tr></thead><tbody>'
  foreach ($mk in $ord) {
    $name = if ($unpriced.ContainsKey($mk)) { Paint 'r' (Hesc $mk) 'No price found for this model, so it was costed at the default Sonnet rates' } else { Hesc $mk }
    o ('<tr><td>' + $name + '</td>')
    for ($p = 1; $p -le $nper; $p++) {
      $c = [double]$PM_cost[$p][$mk]
      if ([double]$PM_calls[$p][$mk] -eq 0) { o '<td><small>–</small></td>' }
      else { o ('<td><b>' + (Money $c) + '</b><small>' + (Commas $PM_calls[$p][$mk]) + ' calls · ' + (Pct $c $P_cost[$p]) + '</small></td>') }
    }
    if ($nper -gt 1) { o ('<td><b>' + (Money $mod_cost[$mk]) + '</b><small>' + (Commas $mod_calls[$mk]) + ' calls · ' + (Pct $mod_cost[$mk] $total_cost) + '</small></td>') }
    o '</tr>'
  }
  o "<tr class='tot'><td>All models</td>"
  for ($p = 1; $p -le $nper; $p++) { o ('<td>' + (Money $P_cost[$p]) + '<small>' + (Commas $P_calls[$p]) + ' calls</small></td>') }
  if ($nper -gt 1) { o ('<td>' + (Money $total_cost) + '<small>' + (Commas $uniq_u) + ' calls</small></td>') }
  o '</tr></tbody></table></div>'
  o '</details></section>'
}

# --- Top lists: by item (bars per period) or by period (lists per period) ---
function Write-Top {
  $unitName = if ($COMPARE) { $COMPARE } else { 'period' }
  $byPeriod = if ($nper -gt 1) { '"By ' + $unitName + '" lists the top items in each period. ' } else { '' }
  o ("<section><details open><summary>What was used · top " + $top_n + "</summary><p class='note cd'>The tools, MCP servers, individual MCP tools, Bash commands (the first word of each), files read, skills, slash commands, helper agents (subagents) and projects you used most. Each number is how many times it was used (for projects, how many API calls), with its share of that list. " + '"By item" ranks them. ' + $byPeriod + 'The small note next to a name shows how use changed in the last finished period compared with the one before it (new, or up or down by more than 10%). A period still in progress is left out of that comparison.</p>')
  o "<input type='radio' name='tv' id='tv1' class='tv' checked><label for='tv1' class='tvl l1'>By item</label>"
  if ($nper -gt 1) { o ("<input type='radio' name='tv' id='tv2' class='tv'><label for='tv2' class='tvl l2'>By " + $unitName + '</label>') }
  $tl = if ($pe[$nper] -gt $NOW) { $nper - 1 } else { $nper }   # trend compares the last finished period with the one before it
  o "<div class='views'><div class='by-item grid'>"
  foreach ($cat in $hcats) {
    $tot = $ctot[$cat]
    o ("<div class='card'><div class='kh' style='margin-bottom:6px'>" + $cat_title[$cat] + '</div>')
    if ($tot.Count -eq 0) { o "<p class='note'>None in this range.</p></div>"; continue }
    $ord = SortDesc $tot
    $n = $ord.Count
    $gtot = 0.0
    foreach ($k in $ord) { $gtot += $tot[$k] }
    $lim = [math]::Min($n, $top_n)
    $mx = 0.0
    for ($i = 0; $i -lt $lim; $i++) { for ($p = 1; $p -le $nper; $p++) { $c = Cnt $cat $p $ord[$i]; if ($c -gt $mx) { $mx = $c } } }
    o "<ul class='top'>"
    for ($i = 0; $i -lt $lim; $i++) {
      $key = $ord[$i]
      $trend = ''
      if ($tl -gt 1) {
        $a1 = [double](Cnt $cat $tl $key); $a0 = [double](Cnt $cat ($tl - 1) $key)
        if ($a1 -gt 0 -and $a0 -eq 0) { $trend = "<small class='tr new'>new</small>" }
        elseif ($a0 -gt 0 -and $a1 -eq 0) { $trend = "<small class='tr'>not used</small>" }
        elseif ($a0 -gt 0 -and $a1 -gt $a0 * 1.1) { $trend = "<small class='tr'>▲ " + (F (($a1 - $a0) / $a0 * 100) 'F0') + '%</small>' }
        elseif ($a0 -gt 0 -and $a1 -lt $a0 * 0.9) { $trend = "<small class='tr'>▼ " + (F (($a0 - $a1) / $a0 * 100) 'F0') + '%</small>' }
      }
      o ("<li><div class='name'><span title='" + (Hesc $key) + "'>" + (Hesc $key) + $trend + '</span><b>' + (Commas $tot[$key]) + " <small class='sh'>" + (Pct $tot[$key] $gtot) + "</small></b></div><div class='bars'>")
      for ($p = 1; $p -le $nper; $p++) {
        $c = [double](Cnt $cat $p $key)
        $w = if ($mx -gt 0) { $c / $mx * 100 } else { 0 }
        if ($w -gt 0 -and $w -lt 1) { $w = 1 }
        $num = if ($nper -gt 1) { Commas $c } else { '' }
        o ("<div class='bar' title='" + (Hesc $plab[$p]) + "'><i style='width:" + (F $w 'F2') + '%;background:' + (PColor $p) + "'></i><em>" + $num + '</em></div>')
      }
      o '</div></li>'
    }
    o '</ul>'
    if ($n -gt $lim) { o ("<p class='note' style='margin:8px 0 0'>… " + ($n - $lim) + ' more</p>') }
    o '</div>'
  }
  o '</div>'
  if ($nper -gt 1) {
    o "<div class='by-period'>"
    for ($p = 1; $p -le $nper; $p++) {
      o ("<div class='card pcard'><div class='kh'><i class='chip' style='background:" + (PColor $p) + "'></i>" + (Hesc $plab[$p]) + "</div><div class='kl' style='margin-bottom:0'>" + (Hesc $plong[$p]) + "</div><div class='pgrid'>")
      foreach ($cat in $hcats) {
        $vals = $cnt[$cat][$p]
        $keys = SortDesc $vals
        $n = $keys.Count
        o ('<div><h3>' + $cat_title[$cat] + '</h3>')
        if ($n -eq 0) { o "<p class='note' style='margin:0'>None</p></div>"; continue }
        $lim = [math]::Min($n, $top_n)
        $mx = [double]$vals[$keys[0]]
        o "<ul class='mini'>"
        for ($i = 0; $i -lt $lim; $i++) {
          $key = $keys[$i]
          o ("<li><div class='name'><span title='" + (Hesc $key) + "'>" + (Hesc $key) + '</span><b>' + (Commas $vals[$key]) + "</b></div><i style='width:" + (F ($vals[$key] / $mx * 100) 'F1') + '%;background:' + (PColor $p) + "'></i></li>")
        }
        o '</ul>'
        if ($n -gt $lim) { o ("<p class='note' style='margin:4px 0 0;font-size:12px'>… " + ($n - $lim) + ' more</p>') }
        o '</div>'
      }
      o '</div></div>'
    }
    o '</div>'
  }
  o '</div></details></section>'
}

# --- Requests and cost: per day, by hour of the day, by day of the week, and per project ---
function Write-Activity {
  o "<section><details open><summary>Requests and cost</summary><p class='note cd'>When you use Claude Code and where the money goes. A <b>request</b> is one API call. The charts show cost and requests over time, then by hour of the day and day of the week (your local time), and last by project.</p><div class='card'>"
  Write-Chart
  Write-HourCharts
  Write-ProjectCost
  o '</div></details></section>'
}

# Bars = cost stacked by period (left axis), line = requests (right axis), for n slots such as hours or weekdays
function ComboChart([string]$title, [string]$desc, [int]$n, $lab, $cntArr, $costArr, [int]$tick) {
  $maxc = 0.0; $maxn = 0.0
  for ($i = 1; $i -le $n; $i++) {
    $tot = 0.0; $cost = 0.0
    for ($p = 1; $p -le $nper; $p++) { $tot += $cntArr[$p][$i - 1]; $cost += $costArr[$p][$i - 1] }
    if ($tot -gt $maxn) { $maxn = $tot }
    if ($cost -gt $maxc) { $maxc = $cost }
  }
  if ($maxn -eq 0) { return }
  $yc = NiceMax $maxc; $yn = NiceMax $maxn
  $gW = 1100; $gH = 300; $gL = 70; $gR = 64; $gT = 14; $gB = 36
  $pw = $gW - $gL - $gR; $ph = $gH - $gT - $gB; $slot = $pw / $n; $bw = $slot * 0.7
  o ("<h3 class='ch'>" + $title + "</h3><p class='note cd'>" + $desc + "</p><div class='keys'>")
  if ($nper -gt 1) { PeriodKeys } else { o ("<span><i class='chip' style='background:" + (PColor 1) + "'></i>Cost (left axis)</span>") }
  o "<span><i class='lk'></i>Requests (right axis)</span></div><div class='chartwrap'>"
  o ("<svg class='chart' viewBox='0 0 $gW $gH' role='img' aria-label='" + (Hesc $title) + "'>")
  for ($g = 0; $g -le 4; $g++) {
    $y = $gT + $ph - $ph * $g / 4
    o ("<line class='gl' x1='$gL' x2='" + ($gW - $gR) + "' y1='" + (F $y 'F1') + "' y2='" + (F $y 'F1') + "'/>")
    o ("<text x='" + ($gL - 10) + "' y='" + (F ($y + 4) 'F1') + "' text-anchor='end'>" + (Money ($yc * $g / 4)) + '</text>')
    o ("<text x='" + ($gW - $gR + 10) + "' y='" + (F ($y + 4) 'F1') + "'>" + (FmtTok ($yn * $g / 4)) + '</text>')
  }
  $pts = ''
  for ($i = 1; $i -le $n; $i++) {
    $x = $gL + $slot * ($i - 1) + ($slot - $bw) / 2
    $tot = 0.0; $cost = 0.0
    for ($p = 1; $p -le $nper; $p++) { $tot += $cntArr[$p][$i - 1]; $cost += $costArr[$p][$i - 1] }
    $tip = $lab[$i] + ': ' + (Money $cost) + ' · ' + (Commas $tot) + ' requests'
    o ('<g><title>' + (Hesc $tip) + "</title><rect class='hit' x='" + (F ($gL + $slot * ($i - 1)) 'F1') + "' y='$gT' width='" + (F $slot 'F2') + "' height='$ph'/>")
    $y = $gT + $ph
    for ($p = 1; $p -le $nper; $p++) {
      $c = $costArr[$p][$i - 1]
      if ($c -le 0) { continue }
      $hgt = $c / $yc * $ph; $y -= $hgt
      $rx = if ($bw -gt 6) { 2 } else { 0 }
      o ("<rect x='" + (F $x 'F1') + "' y='" + (F $y 'F1') + "' width='" + (F $bw 'F2') + "' height='" + (F $hgt 'F2') + "' rx='$rx' fill='" + (PColor $p) + "'/>")
    }
    o '</g>'
    $pts += (F ($gL + $slot * ($i - 0.5)) 'F1') + ',' + (F ($gT + $ph - $tot / $yn * $ph) 'F1') + ' '
    if (($i - 1) % $tick -eq 0) { o ("<text x='" + (F ($gL + $slot * ($i - 0.5)) 'F1') + "' y='" + ($gH - $gB + 22) + "' text-anchor='middle'>" + $lab[$i] + '</text>') }
  }
  o ("<polyline class='ln' points='" + $pts + "'/>")
  o '</svg></div>'
}

function Write-HourCharts {
  $lab = @('') + @(0..23 | ForEach-Object { $_.ToString('00') })
  ComboChart 'Cost and requests by hour of the day' 'All your days added together and split into the 24 hours of the day (your local time, 24-hour clock). The bars show the cost in each hour; the line shows the requests. Tall bars are the hours you use Claude Code the most.' 24 $lab $TH_n $TH_c 2
  $lab = @('', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun')
  ComboChart 'Cost and requests by day of the week' 'The same numbers grouped by day of the week. The bars show the cost; the line shows the requests. It shows which days you lean on Claude Code the most.' 7 $lab $TW_n $TW_c 1
}

# Cost per project: the folder each session ran in. Horizontal bars, one row per project, stacked by period.
function Write-ProjectCost {
  $ord = SortDesc $PJ_t
  $n = $ord.Count
  if ($n -eq 0) { return }
  $lim = [math]::Min($n, $top_n)
  $tcost = 0.0
  foreach ($k in $ord) { $tcost += $PJ_t[$k] }
  $mx = 0.0
  for ($i = 0; $i -lt $lim; $i++) { if ($PJ_t[$ord[$i]] -gt $mx) { $mx = $PJ_t[$ord[$i]] } }
  $mx = NiceMax $mx
  $rh = 34; $gW = 1100; $gL = 190; $gR = 150; $gT = 10; $gB = 30
  $pw = $gW - $gL - $gR; $ph = $lim * $rh; $gH = $gT + $ph + $gB
  $split = if ($nper -gt 1) { ', split by period' } else { '' }
  o ("<h3 class='ch'>Cost per project</h3><p class='note cd'>What each project cost, where a project is the folder a session ran in. Each row is one project and the bar length is its cost" + $split + '. The label on the right is the total and its share of all cost. Showing the top ' + $lim + ' of ' + $n + ' projects.</p>')
  if ($nper -gt 1) { o "<div class='keys'>"; PeriodKeys; o '</div>' }
  o "<div class='chartwrap'><svg class='chart' viewBox='0 0 $gW $gH' role='img' aria-label='Cost per project'>"
  for ($g = 0; $g -le 4; $g++) {
    $x = $gL + $pw * $g / 4
    o ("<line class='gl' x1='" + (F $x 'F1') + "' x2='" + (F $x 'F1') + "' y1='$gT' y2='" + ($gT + $ph) + "'/>")
    o ("<text x='" + (F $x 'F1') + "' y='" + ($gT + $ph + 20) + "' text-anchor='middle'>" + (Money ($mx * $g / 4)) + '</text>')
  }
  for ($i = 1; $i -le $lim; $i++) {
    $key = $ord[$i - 1]
    $y = $gT + $rh * ($i - 1)
    $lab = $key
    if ($lab.Length -gt 26) { $lab = $lab.Substring(0, 25) + '…' }
    o ('<g><title>' + (Hesc ($key + ': ' + (Money $PJ_t[$key]) + ' · ' + (Pct $PJ_t[$key] $tcost) + ' of all cost')) + "</title><text x='" + ($gL - 10) + "' y='" + (F ($y + $rh / 2 + 4) 'F1') + "' text-anchor='end'>" + (Hesc $lab) + '</text>')
    $run = 0.0
    for ($p = 1; $p -le $nper; $p++) {
      $w = [double]$PJ_c[$p][$key] / $mx * $pw
      if ($w -le 0) { continue }
      o ("<rect x='" + (F ($gL + $run) 'F1') + "' y='" + (F ($y + 5) 'F1') + "' width='" + (F $w 'F2') + "' height='" + ($rh - 10) + "' fill='" + (PColor $p) + "'><title>" + (Hesc ($key + ' · ' + $plab[$p] + ': ' + (Money $PJ_c[$p][$key]) + ' · ' + (Commas $PJ_n[$p][$key]) + ' requests')) + '</title></rect>')
      $run += $w
    }
    o ("<text x='" + (F ($gL + $run + 8) 'F1') + "' y='" + (F ($y + $rh / 2 + 4) 'F1') + "'>" + (Money $PJ_t[$key]) + ' · ' + (Pct $PJ_t[$key] $tcost) + '</text></g>')
  }
  o '</svg></div>'
}

if ($HtmlV) {
  $htmlPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($HtmlV)
  Write-HtmlReport
  [IO.File]::WriteAllText($htmlPath, ($HtmlLines -join "`n") + "`n", $utf8)
  Out ("`n  " + $CB + 'HTML report:' + $CR + ' ' + $htmlPath + "`n")
}
Out "`n"

Write-Output $sb.ToString()
