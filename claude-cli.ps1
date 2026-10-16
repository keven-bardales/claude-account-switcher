# claude-cli.ps1
# Account-aware launcher for Claude Code (Windows PowerShell 5.1+).
# https://github.com/keven-bardales/claude-account-switcher
#
# Why: Claude Code uses ONE account per config directory. If you have more than
# one account (e.g. personal + work), it's easy to start Claude with the wrong
# one in the wrong project. This wraps `claude` so that every run:
#   - resolves the account from your folder/repo (you configure the rules once),
#   - SHOWS you which account it will use,
#   - asks you to confirm before launching,
#   - passes all your flags through unchanged.
#
# Personal is the safe default. Another account is used ONLY where YOU mapped it
# in ~/.claude-accounts.json. Config CLI: `cca` (run `cca help`).

$script:CCFile = Join-Path $HOME ".claude-accounts.json"

# --- config -----------------------------------------------------------------

function Get-CCConfig {
  if (-not (Test-Path -LiteralPath $script:CCFile)) { return $null }
  try {
    return (Get-Content -LiteralPath $script:CCFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return 'INVALID'
  }
}

function Initialize-CCConfig {
  $starter = [ordered]@{
    default  = 'personal'
    profiles = [ordered]@{ personal = ''; work = (Join-Path $HOME '.claude-work') }
    byPath   = [ordered]@{ }
    byOrg    = [ordered]@{ }
  }
  ($starter | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $script:CCFile -Encoding UTF8
  Write-Host ("Created " + $script:CCFile) -ForegroundColor Green
  Write-Host "Edit it (cca edit) to add profiles + folder/org rules." -ForegroundColor DarkGray
}

function Get-CCConfigDir([object]$cfg, [string]$profileName) {
  if ($cfg -and ($cfg -ne 'INVALID') -and $cfg.profiles) {
    $p = $cfg.profiles.PSObject.Properties[$profileName]
    if ($p) { return [string]$p.Value }
  }
  return ''
}

function Get-CCGitOrg {
  $url = $null
  try { $url = (& git config --get remote.origin.url 2>$null) } catch {}
  if (-not $url) { return $null }
  $clean = ([string]$url).Trim()
  $clean = ($clean -replace '\.git$', '') -replace ':', '/'
  $parts = @($clean -split '/' | Where-Object { $_ -ne '' })
  if ($parts.Count -ge 2) { return $parts[$parts.Count - 2] }
  return $null
}

# Returns @{ Profile; ConfigDir; Reason; Source } - Source: byPath|byOrg|default|missing|invalid
function Resolve-CCAccount {
  $cfg = Get-CCConfig
  if ($null -eq $cfg)     { return @{ Profile='personal'; ConfigDir=''; Reason='accounts config not found'; Source='missing' } }
  if ($cfg -eq 'INVALID') { return @{ Profile='personal'; ConfigDir=''; Reason='accounts config is invalid JSON'; Source='invalid' } }

  $default = 'personal'
  if ($cfg.default) { $default = [string]$cfg.default }

  $cwd = (Get-Location).Path

  # 1) byPath - longest matching prefix wins (a folder OR a specific repo)
  $bestProfile = $null; $bestBase = $null; $bestLen = -1
  if ($cfg.byPath) {
    foreach ($prop in $cfg.byPath.PSObject.Properties) {
      $base = ([string]$prop.Name).TrimEnd('\', '/')
      if ($base.Length -eq 0) { continue }
      if ($cwd.Equals($base, [System.StringComparison]::OrdinalIgnoreCase) -or
          $cwd.StartsWith($base + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($base.Length -gt $bestLen) { $bestLen = $base.Length; $bestBase = $base; $bestProfile = [string]$prop.Value }
      }
    }
  }
  if ($bestProfile) {
    return @{ Profile=$bestProfile; ConfigDir=(Get-CCConfigDir $cfg $bestProfile); Reason=("path match: " + $bestBase); Source='byPath' }
  }

  # 2) byOrg - from the repo's git remote owner
  $org = Get-CCGitOrg
  if ($org -and $cfg.byOrg) {
    $op = $cfg.byOrg.PSObject.Properties[$org]
    if ($op) {
      $pf = [string]$op.Value
      return @{ Profile=$pf; ConfigDir=(Get-CCConfigDir $cfg $pf); Reason=("git org: " + $org); Source='byOrg' }
    }
  }

  # 3) default
  return @{ Profile=$default; ConfigDir=(Get-CCConfigDir $cfg $default); Reason='default (no match)'; Source='default' }
}

function Test-CCLoggedIn([string]$configDir) {
  if ([string]::IsNullOrEmpty($configDir)) { $cred = Join-Path $HOME '.claude\.credentials.json' }
  else { $cred = Join-Path $configDir '.credentials.json' }
  return (Test-Path -LiteralPath $cred)
}

function Get-CCRealClaude {
  return (@(Get-Command -Name claude -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1)
}

# --- the wrapper ------------------------------------------------------------

function claude {
  $real = Get-CCRealClaude
  if (-not $real) { Write-Host "X  Real 'claude' executable not found on PATH." -ForegroundColor Red; return }

  $r = Resolve-CCAccount
  $profileName = $r.Profile
  $dir = $r.ConfigDir

  $redir = $false
  try { $redir = [Console]::IsInputRedirected } catch {}
  $autoYes = ($env:CLAUDE_ACCOUNT_YES -eq '1') -or $redir

  # Edge case: config file missing or broken -> ask before proceeding (safe default = personal)
  if ($r.Source -eq 'missing' -or $r.Source -eq 'invalid') {
    Write-Host ""
    Write-Host ("!  " + $r.Reason + ". Safe fallback = PERSONAL.") -ForegroundColor Yellow
    if (-not $autoYes) {
      $a = Read-Host "   Proceed with PERSONAL? [Y]es / [n]o / [r]ecreate config"
      if ($a -match '^[rR]') { Initialize-CCConfig; Write-Host "   Re-run 'claude' now." -ForegroundColor DarkGray; return }
      if ($a -match '^[nN]') { Write-Host "   Cancelled." -ForegroundColor DarkGray; return }
    }
    $profileName = 'personal'; $dir = ''
  }

  $loggedIn = Test-CCLoggedIn $dir
  if ($profileName -eq 'personal') { $tag = '[personal]' } else { $tag = '[' + $profileName + ']' }

  Write-Host ""
  Write-Host "  +-- Claude account --------------------------------" -ForegroundColor DarkGray
  Write-Host ("  | account : " + $profileName + " " + $tag) -ForegroundColor Cyan
  Write-Host ("  | why     : " + $r.Reason) -ForegroundColor DarkGray
  if ([string]::IsNullOrEmpty($dir)) { Write-Host "  | config  : default (~/.claude)" -ForegroundColor DarkGray }
  else { Write-Host ("  | config  : " + $dir) -ForegroundColor DarkGray }
  if (-not $loggedIn) { Write-Host "  | login   : NOT logged in yet -> Claude will prompt you to /login" -ForegroundColor Yellow }
  Write-Host "  +--------------------------------------------------" -ForegroundColor DarkGray

  if (-not $autoYes) {
    $cfg = Get-CCConfig
    $names = @()
    if ($cfg -and ($cfg -ne 'INVALID') -and $cfg.profiles) { $names = @($cfg.profiles.PSObject.Properties.Name) }
    $opts = ''
    for ($i = 0; $i -lt $names.Count; $i++) { $opts += ("  " + ($i + 1) + ") " + $names[$i]) }
    if (-not $opts) { $opts = '  (no profiles)' }
    Write-Host ("  [Enter] = " + $profileName + "   |" + $opts + "   |  n = cancel") -ForegroundColor DarkGray
    $resp = Read-Host "  Account?"
    $n = 0
    if ([int]::TryParse($resp, [ref]$n) -and $n -ge 1 -and $n -le $names.Count) { $resp = $names[$n - 1] }
    if ($resp -match '^(n|no)$') { Write-Host "  Cancelled." -ForegroundColor DarkGray; return }
    if ($resp -and ($resp -notmatch '^[yY]$') -and ($resp -ne $profileName)) {
      if ($cfg -and ($cfg -ne 'INVALID') -and $cfg.profiles -and $cfg.profiles.PSObject.Properties[$resp]) {
        $profileName = $resp; $dir = (Get-CCConfigDir $cfg $resp)
        Write-Host ("  -> override: " + $profileName) -ForegroundColor Cyan
      } else {
        Write-Host ("  Unknown profile '" + $resp + "'. Cancelled.") -ForegroundColor Red; return
      }
    }
  }

  # Launch the REAL claude with the right config dir, then restore the env.
  $had = Test-Path Env:\CLAUDE_CONFIG_DIR
  $prev = $env:CLAUDE_CONFIG_DIR
  try {
    if ([string]::IsNullOrEmpty($dir)) {
      Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
    } else {
      if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
      $env:CLAUDE_CONFIG_DIR = $dir
    }
    & $real.Source @args
  } finally {
    if ($had) { $env:CLAUDE_CONFIG_DIR = $prev } else { Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
  }
}

# --- config CLI: cca --------------------------------------------------------

function cca {
  param(
    [Parameter(Position=0)][string]$Cmd = 'help',
    [Parameter(Position=1)][string]$A,
    [Parameter(Position=2)][string]$B
  )
  switch ($Cmd) {
    'which' {
      $r = Resolve-CCAccount
      Write-Host ($r.Profile + "   (" + $r.Reason + ")") -ForegroundColor Cyan
    }
    'list' {
      if (Test-Path -LiteralPath $script:CCFile) { Get-Content -LiteralPath $script:CCFile -Raw }
      else { Write-Host ("No config at " + $script:CCFile + "  (run: cca init)") -ForegroundColor Yellow }
    }
    'edit' { notepad $script:CCFile }
    'path' { Write-Host $script:CCFile }
    'init' { Initialize-CCConfig }
    'set' {
      if (-not $A) { Write-Host "Usage: cca set <profile> [path]   (path defaults to current folder)"; return }
      $cfg = Get-CCConfig
      if ($null -eq $cfg -or $cfg -eq 'INVALID') { Write-Host "Config missing/invalid. Run: cca init" -ForegroundColor Yellow; return }
      if (-not ($cfg.profiles -and $cfg.profiles.PSObject.Properties[$A])) {
        Write-Host ("Unknown profile '" + $A + "'. Known: " + (($cfg.profiles.PSObject.Properties.Name) -join ', ')) -ForegroundColor Red; return
      }
      if ($B) { $target = $B } else { $target = (Get-Location).Path }
      if (-not $cfg.byPath) { $cfg | Add-Member -NotePropertyName byPath -NotePropertyValue (New-Object psobject) -Force }
      $cfg.byPath | Add-Member -NotePropertyName $target -NotePropertyValue $A -Force
      ($cfg | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $script:CCFile -Encoding UTF8
      Write-Host ("Mapped  " + $target + "  ->  " + $A) -ForegroundColor Green
    }
    'login' {
      $cfg = Get-CCConfig
      if ($null -eq $cfg -or $cfg -eq 'INVALID' -or -not ($cfg.profiles -and $cfg.profiles.PSObject.Properties[$A])) {
        $known = if ($cfg -and $cfg -ne 'INVALID') { ($cfg.profiles.PSObject.Properties.Name) -join ', ' } else { '(none)' }
        Write-Host ("Usage: cca login <profile>   known: " + $known) -ForegroundColor Yellow; return
      }
      $dir = (Get-CCConfigDir $cfg $A)
      $real = Get-CCRealClaude
      if (-not $real) { Write-Host "X  Real 'claude' executable not found." -ForegroundColor Red; return }
      $had = Test-Path Env:\CLAUDE_CONFIG_DIR; $prev = $env:CLAUDE_CONFIG_DIR
      try {
        if ([string]::IsNullOrEmpty($dir)) { Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
        else { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }; $env:CLAUDE_CONFIG_DIR = $dir }
        Write-Host ("Opening Claude for profile '" + $A + "'. Inside, run  /login  if it doesn't prompt automatically.") -ForegroundColor Cyan
        & $real.Source @args
      } finally {
        if ($had) { $env:CLAUDE_CONFIG_DIR = $prev } else { Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
      }
    }
    default {
      Write-Host @"
cca - Claude account config
  cca which              show which account THIS folder resolves to
  cca list               print ~/.claude-accounts.json
  cca edit               open the config in Notepad
  cca set <profile> [p]  map a folder (default: current) to a profile
  cca login <profile>    open Claude in a profile so you can /login
  cca init               (re)create a starter config
  cca path               print the config file path

Tip: at the 'claude' confirm prompt, type a profile name to override once.
     Set CLAUDE_ACCOUNT_YES=1 to skip the prompt (scripts/CI).
"@
    }
  }
}
