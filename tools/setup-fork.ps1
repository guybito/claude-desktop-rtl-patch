<#
.SYNOPSIS
    Turns a GitHub fork of this repo into a self-signed release channel.
.DESCRIPTION
    Run from a clone of YOUR fork. It:
      1. Creates your own RSA-4096 signing key (once) at $HOME\.claude-rtl-signing.key,
         readable only by you. Back it up -- losing it means re-installing manually.
      2. Points install.ps1 / patch.ps1 (installer, update helper, watcher) at
         raw.githubusercontent.com/<GitHubUser>/claude-desktop-rtl-patch/<Branch>.
      3. Embeds YOUR public key in install.ps1 (the trust anchor that gets pinned).
      4. Signs patch.ps1 with tools\sign-release.ps1 and checks it with
         tools\verify-signature.ps1.
    The signature check is unchanged: the installer, the "Update Claude RTL"
    shortcut and the auto re-patch watcher still refuse any patch.ps1 that is not
    signed -- only now by your key, from your fork.

    Idempotent: re-run it after every "Sync fork" with the upstream repo (the
    merge brings the upstream URLs/key back; this script re-applies yours and
    re-signs).
.EXAMPLE
    .\tools\setup-fork.ps1 -GitHubUser my-github-name
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$')]
    [string]$GitHubUser,
    [ValidatePattern('^[A-Za-z0-9._/-]{1,100}$')]
    [string]$Branch  = 'main',
    [string]$KeyPath = (Join-Path $HOME '.claude-rtl-signing.key')
)

$ErrorActionPreference = 'Stop'
$repoRoot    = Split-Path -Parent $PSScriptRoot
$installPath = Join-Path $repoRoot 'install.ps1'
$patchPath   = Join-Path $repoRoot 'patch.ps1'
$utf8NoBom   = New-Object System.Text.UTF8Encoding $false

foreach ($p in @($installPath, $patchPath)) {
    if (-not (Test-Path $p)) { throw "Missing $p -- run this from a clone of the repo." }
}

# --- 1. Signing key (created once, never committed) ---
if (-not (Test-Path $KeyPath)) {
    Write-Host "Creating a new RSA-4096 signing key at $KeyPath ..." -ForegroundColor Cyan
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider 4096
    try {
        $k = $rsa.ExportParameters($true)
        $priv = [ordered]@{
            Modulus  = [Convert]::ToBase64String($k.Modulus)
            Exponent = [Convert]::ToBase64String($k.Exponent)
            D        = [Convert]::ToBase64String($k.D)
            P        = [Convert]::ToBase64String($k.P)
            Q        = [Convert]::ToBase64String($k.Q)
            DP       = [Convert]::ToBase64String($k.DP)
            DQ       = [Convert]::ToBase64String($k.DQ)
            InverseQ = [Convert]::ToBase64String($k.InverseQ)
        }
        [IO.File]::WriteAllText($KeyPath, ($priv | ConvertTo-Json -Compress), $utf8NoBom)
    } finally { $rsa.PersistKeyInCsp = $false; $rsa.Dispose() }
    if ($env:OS -eq 'Windows_NT') {
        # Owner-only access: drop inherited ACEs, grant just the current user.
        & icacls.exe $KeyPath /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
    }
    Write-Host "Key created. BACK IT UP (password manager / encrypted USB). Never commit it." -ForegroundColor Yellow
} else {
    Write-Host "Using existing signing key: $KeyPath" -ForegroundColor Gray
}

$keyObj = Get-Content $KeyPath -Raw | ConvertFrom-Json
if (-not $keyObj.Modulus -or -not $keyObj.Exponent -or -not $keyObj.D) { throw "Signing key at $KeyPath is not valid." }
$pubJson = ([ordered]@{ Modulus = $keyObj.Modulus; Exponent = $keyObj.Exponent }) | ConvertTo-Json -Compress
$pubB64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pubJson))

# --- 2 + 3. Repo URLs and embedded public key ---
$newRaw = "raw.githubusercontent.com/$GitHubUser/claude-desktop-rtl-patch/$Branch"
$rawRe  = 'raw\.githubusercontent\.com/[A-Za-z0-9-]+/claude-desktop-rtl-patch/[A-Za-z0-9._/-]+?(?=/[A-Za-z0-9._-]+\.(?:ps1|sig)\b|[''"])'
$webRe  = 'github\.com/[A-Za-z0-9-]+/claude-desktop-rtl-patch(?=[#''"\s])'
$newWeb = "github.com/$GitHubUser/claude-desktop-rtl-patch"

function Read-Lf([string]$path) { ([IO.File]::ReadAllText($path)) -replace "`r`n", "`n" }

$install = Read-Lf $installPath
$install = [regex]::Replace($install, $rawRe, $newRaw)
$install = [regex]::Replace($install, $webRe, $newWeb)
$keyLineRe = "(?m)^\`$ExpectedPubKey\s*=\s*'[A-Za-z0-9+/=]+'"
if (-not [regex]::IsMatch($install, $keyLineRe)) { throw "ExpectedPubKey line not found in install.ps1." }
$install = [regex]::Replace($install, $keyLineRe, "`$ExpectedPubKey = '$pubB64'")
[IO.File]::WriteAllText($installPath, $install, $utf8NoBom)

$patch = Read-Lf $patchPath
$before = ([regex]::Matches($patch, $rawRe)).Count
$patch = [regex]::Replace($patch, $rawRe, $newRaw)
[IO.File]::WriteAllText($patchPath, $patch, $utf8NoBom)
Write-Host "Pointed installer/updater/watcher at https://$newRaw ($before URLs in patch.ps1)." -ForegroundColor Green

# --- 4. Sign and verify ---
& (Join-Path $PSScriptRoot 'sign-release.ps1') -KeyPath $KeyPath
& (Join-Path $PSScriptRoot 'verify-signature.ps1')
if ($LASTEXITCODE -ne 0) { throw "Signature verification failed." }

$sha = [Security.Cryptography.SHA256]::Create().ComputeHash([Convert]::FromBase64String($pubB64))
$fp  = ([BitConverter]::ToString($sha)).Replace('-', '').ToLower()
Write-Host ""
Write-Host "Done. Your public-key fingerprint (sha256): $fp" -ForegroundColor Green
Write-Host "Next: git add install.ps1 patch.ps1 patch.ps1.sig ; git commit ; git push" -ForegroundColor Cyan
Write-Host "Then install from your fork:" -ForegroundColor Cyan
Write-Host "  irm https://$newRaw/install.ps1 | iex" -ForegroundColor Cyan
