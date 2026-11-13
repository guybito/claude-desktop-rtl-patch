<#
.SYNOPSIS
    One-time install of the Claude update manager from this repository checkout.
.DESCRIPTION
    Run from an elevated PowerShell (Run as administrator):
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\install-update-manager.ps1

    The checkout lives in a folder the user can write, so nothing is executed from
    it. patch.ps1 and patch.ps1.sig are read into memory, verified against the
    public key already pinned in C:\ProgramData\ClaudeRtlPatch, written into an
    admin-only staging folder there, and patch.ps1 -InstallUpdateManager runs from
    that copy. Claude itself is not closed or patched by this step.

    KEEP THIS FILE ASCII-ONLY.
#>
$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'Run this from an elevated PowerShell (Run as administrator).' -ForegroundColor Red; exit 1 }

$repo     = Split-Path -Parent $PSScriptRoot
$stateDir = Join-Path $env:ProgramData 'ClaudeRtlPatch'
$pinFile  = Join-Path $stateDir 'trusted-pubkey.b64'
if (-not (Test-Path -LiteralPath $pinFile)) { Write-Host "No pinned public key at $pinFile - install the RTL patch first." -ForegroundColor Red; exit 1 }

# The state dir must already be admin-only (the RTL patch locked it at install).
$acl = Get-Acl -LiteralPath $stateDir
$owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
$usersWrite = $acl.Access | Where-Object {
    $_.AccessControlType -eq 'Allow' -and
    $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -in @('S-1-5-32-545', 'S-1-5-11', 'S-1-1-0') -and
    ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write)
}
if (($owner -ne 'S-1-5-32-544' -and $owner -ne 'S-1-5-18') -or $usersWrite -or -not $acl.AreAccessRulesProtected) {
    Write-Host "$stateDir is not admin-only - refusing." -ForegroundColor Red; exit 1
}

$bytes = [IO.File]::ReadAllBytes((Join-Path $repo 'patch.ps1'))
$sig   = ([IO.File]::ReadAllText((Join-Path $repo 'patch.ps1.sig'))).Trim()
$pinB64 = ([IO.File]::ReadAllText($pinFile)).Trim()
$pin = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pinB64)) | ConvertFrom-Json
$prm = New-Object Security.Cryptography.RSAParameters
$prm.Modulus = [Convert]::FromBase64String($pin.Modulus); $prm.Exponent = [Convert]::FromBase64String($pin.Exponent)
$rsa = [Security.Cryptography.RSA]::Create(); $rsa.ImportParameters($prm)
if (-not $rsa.VerifyData($bytes, [Convert]::FromBase64String($sig), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)) {
    Write-Host 'patch.ps1 does not match the pinned key (not signed, or changed after signing) - refusing.' -ForegroundColor Red; exit 1
}
Write-Host "patch.ps1 verified against the pinned key ($($bytes.Length) bytes)." -ForegroundColor Green

$stage = Join-Path $stateDir ('install-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null    # inherits the admin-only ACL
try {
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    [IO.File]::WriteAllText((Join-Path $stage 'patch.ps1'), $text, (New-Object Text.UTF8Encoding $true))
    [IO.File]::WriteAllText((Join-Path $stage 'patch.ps1.sig'), $sig, (New-Object Text.UTF8Encoding $false))
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $stage 'patch.ps1') -InstallUpdateManager
    $rc = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
if ($rc -ne 0) { Write-Host "Install failed (exit $rc)." -ForegroundColor Red; exit $rc }

# The verified copy the protected repair task runs: the exact signed bytes and the
# signature, written into the admin-only state dir (newer builds are never replaced).
$dest = Join-Path $stateDir 'patch-local.ps1'
$buildOf = { param([byte[]]$b) $m = [regex]::Match([Text.Encoding]::UTF8.GetString($b), '(?m)^\$script:PatchBuild\s*=\s*([0-9]+)\s*$'); if ($m.Success) { [int64]$m.Groups[1].Value } else { [int64]0 } }
$newBuild = & $buildOf $bytes
$haveBuild = if (Test-Path -LiteralPath $dest) { & $buildOf ([IO.File]::ReadAllBytes($dest)) } else { [int64]0 }
if ($newBuild -ge $haveBuild) {
    [IO.File]::WriteAllBytes($dest, $bytes)
    [IO.File]::WriteAllText("$dest.sig", $sig, (New-Object Text.UTF8Encoding $false))
    Write-Host "Verified patch.ps1 (build $newBuild) stored for unattended repairs." -ForegroundColor Green
} else {
    Write-Host "Kept the newer verified copy already stored (build $haveBuild)." -ForegroundColor Yellow
}
Write-Host 'Done.' -ForegroundColor Green
