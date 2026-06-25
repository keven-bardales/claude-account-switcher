# install.ps1 - run from the cloned repo:
#   powershell -ExecutionPolicy Bypass -File install.ps1
$ErrorActionPreference = 'Stop'

$dest = Join-Path $HOME '.claude-cli.ps1'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'claude-cli.ps1') -Destination $dest -Force
Write-Host ("Installed " + $dest) -ForegroundColor Green

$cfg = Join-Path $HOME '.claude-accounts.json'
if (-not (Test-Path -LiteralPath $cfg)) {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'claude-accounts.example.json') -Destination $cfg -Force
  Write-Host ("Created " + $cfg + "  (edit it: cca edit)") -ForegroundColor Green
} else {
  Write-Host ($cfg + " already exists - left as is") -ForegroundColor Yellow
}

$prof = $PROFILE
$dir = Split-Path $prof -Parent
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$already = (Test-Path -LiteralPath $prof) -and (Select-String -LiteralPath $prof -SimpleMatch '.claude-cli.ps1' -Quiet)
if ($already) {
  Write-Host ("Profile already wired: " + $prof) -ForegroundColor Yellow
} else {
  $block = @'

# Claude account-aware launcher (claude-account-switcher)
. "$HOME\.claude-cli.ps1"
'@
  Add-Content -LiteralPath $prof -Value $block
  Write-Host ("Wired profile: " + $prof) -ForegroundColor Green
}

Write-Host ""
Write-Host "Done. Open a NEW PowerShell window (or run:  . `$PROFILE ) to activate." -ForegroundColor Cyan
Write-Host "Then run:  cca edit   to set your profiles + folder/org rules." -ForegroundColor Cyan
