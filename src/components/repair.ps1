# Claude RTL Patch -- protected repair runner (repair.ps1).
#
# Lives in C:\ProgramData\ClaudeRtlPatch (Administrators/SYSTEM write only) and is
# started two ways:
#   * By the "ClaudeRtlPatchRepair" scheduled task, as SYSTEM, with NO arguments.
#     Any process of the signed-in user may start that task, so this path takes no
#     input at all: it re-patches the installed Claude only when it is not patched
#     yet, from the local copy of patch.ps1 that was verified against the pinned key.
#   * By the "Update Claude RTL" shortcut through a UAC prompt with -Refresh: fetches
#     the newest signed patch.ps1 from GitHub, verifies it, refuses older builds
#     (rollback protection), stores it and re-patches.
#
# Hardening (see docs/SECURITY-update-manager.md):
#   - The environment is rebuilt from fixed values before any cmdlet runs, so
#     nothing the user can set (PATH, PSModulePath, NODE_OPTIONS, TEMP...) reaches
#     the elevated code. As SYSTEM the task never sees the user's environment.
#   - Code runs only from this admin-only folder, never from %TEMP%.
#   - patch.ps1 is verified against the pinned public key right before it runs.
#
# KEEP THIS FILE ASCII-ONLY (embedded in patch.ps1, read by PS 5.1 as ANSI).

param(
    [switch]$Refresh,   # UAC path only: fetch + verify the newest signed patch.ps1
    [switch]$Force      # UAC path only: re-patch even when already patched
)

# ---- 1. Fixed environment, before anything else runs -------------------------
$sys = [Environment]::GetFolderPath('System')                  # C:\Windows\System32
$win = Split-Path -Parent $sys
$pf  = [Environment]::GetFolderPath('ProgramFiles')
$env:PATH         = "$sys;$win;$sys\Wbem;$sys\WindowsPowerShell\v1.0;$pf\nodejs"
$env:PSModulePath = "$sys\WindowsPowerShell\v1.0\Modules;$pf\WindowsPowerShell\Modules"
$env:PATHEXT      = '.COM;.EXE;.BAT;.CMD'
$env:ComSpec      = "$sys\cmd.exe"
foreach ($v in @('NODE_OPTIONS', 'NODE_PATH', 'NODE_EXTRA_CA_CERTS', 'PSExecutionPolicyPreference',
                 'CLAUDE_RTL_AUTO', 'CLAUDE_RTL_TRUSTED_PUBKEY', 'CLAUDE_RTL_CUSTOM_FONT',
                 'CLAUDE_RTL_ARABIC_FONT', 'CLAUDE_RTL_CUSTOM_FONT_SCOPE')) {
    [Environment]::SetEnvironmentVariable($v, $null, 'Process')
}
Get-ChildItem Env: | Where-Object { $_.Name -like 'npm_config_*' } | ForEach-Object {
    [Environment]::SetEnvironmentVariable($_.Name, $null, 'Process')
}

$ErrorActionPreference = 'Stop'
$StateDir   = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeRtlPatch'
$PinFile    = Join-Path $StateDir 'trusted-pubkey.b64'
$LocalPatch = Join-Path $StateDir 'patch-local.ps1'
$LocalSig   = Join-Path $StateDir 'patch-local.ps1.sig'
$RunFile    = Join-Path $StateDir 'patch-run.ps1'
$StatusFile = Join-Path $StateDir 'repair-status.json'
$StateFile  = Join-Path $StateDir 'state.json'
$LogFile    = Join-Path $StateDir 'repair.log'
$WorkTemp   = Join-Path $StateDir 'tmp'
$RepoBase   = 'https://raw.githubusercontent.com/guybito/claude-desktop-rtl-patch/main'
# Only the Microsoft Store / MSIX build of Claude, signed by Anthropic.
$ClaudeDirRe = '^[A-Za-z]:\\Program Files\\WindowsApps\\Claude_(\d+(?:\.\d+){1,3})_x64__pzs8sxrjxfjjc$'

function Write-RLog([string]$Msg) {
    try {
        if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 512KB) {
            Move-Item -LiteralPath $LogFile "$LogFile.old" -Force
        }
        "$([DateTime]::Now.ToString('o'))  [$([Security.Principal.WindowsIdentity]::GetCurrent().Name)]  $Msg" |
            Out-File -Append -FilePath $LogFile -Encoding UTF8
    } catch {}
    if ($Refresh -or $Force) { Write-Host $Msg }
}

function Write-Status([string]$Result, [string]$Version, [string]$Message) {
    try {
        [ordered]@{
            at      = (Get-Date).ToUniversalTime().ToString('o')
            result  = $Result
            version = $Version
            message = $Message
        } | ConvertTo-Json | Set-Content -LiteralPath $StatusFile -Encoding UTF8
    } catch {}
}

# True only for a real folder owned by Administrators/SYSTEM that standard users
# cannot write to. Everything elevated in this script depends on it.
function Test-StateDirLocked {
    $item = Get-Item -LiteralPath $StateDir -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
    $acl = Get-Acl -LiteralPath $StateDir
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne 'S-1-5-32-544' -and $owner -ne 'S-1-5-18') { return $false }
    if (-not $acl.AreAccessRulesProtected) { return $false }
    $writeBits = [Security.AccessControl.FileSystemRights]::WriteData -bor
                 [Security.AccessControl.FileSystemRights]::AppendData -bor
                 [Security.AccessControl.FileSystemRights]::Delete -bor
                 [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
                 [Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($ace in $acl.Access) {
        if ($ace.AccessControlType -ne 'Allow') { continue }
        $sid = $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($sid -in @('S-1-5-32-544', 'S-1-5-18', 'S-1-3-0')) { continue }
        if ($ace.FileSystemRights -band $writeBits) { return $false }
    }
    return $true
}

function Get-PinnedRsa {
    $b64 = ([IO.File]::ReadAllText($PinFile)).Trim()
    $obj = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
    $p = New-Object Security.Cryptography.RSAParameters
    $p.Modulus  = [Convert]::FromBase64String($obj.Modulus)
    $p.Exponent = [Convert]::FromBase64String($obj.Exponent)
    $rsa = [Security.Cryptography.RSA]::Create()
    $rsa.ImportParameters($p)
    return @{ Rsa = $rsa; B64 = $b64 }
}

function Test-Signature($Rsa, [byte[]]$Bytes, [string]$SigB64) {
    try { $sig = [Convert]::FromBase64String($SigB64.Trim()) } catch { return $false }
    return $Rsa.VerifyData($Bytes, $sig, [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
}

# Build number embedded in patch.ps1 ($script:PatchBuild = N). Old releases have
# none, which reads as 0 and is therefore never accepted over a newer local copy.
function Get-PatchBuild([byte[]]$Bytes) {
    $text = [Text.Encoding]::UTF8.GetString($Bytes)
    $m = [regex]::Match($text, '(?m)^\$script:PatchBuild\s*=\s*([0-9]+)\s*$')
    if ($m.Success) { return [int64]$m.Groups[1].Value }
    return [int64]0
}

function Get-RemotePatch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $wc = New-Object Net.WebClient
    return @{ Bytes = $wc.DownloadData("$RepoBase/patch.ps1"); Sig = $wc.DownloadString("$RepoBase/patch.ps1.sig").Trim() }
}

# Newest Claude package that is fully installed (not merely staged) for some user.
function Get-InstalledClaude {
    $pkgs = @(Get-AppxPackage -AllUsers -Name 'Claude' -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InstallLocation -match $ClaudeDirRe -and (Test-Path -LiteralPath $_.InstallLocation) -and
            @($_.PackageUserInformation | Where-Object { "$($_.InstallState)" -eq 'Installed' }).Count -gt 0
        } | Sort-Object { [version]$_.Version } -Descending)
    if ($pkgs.Count -eq 0) { return $null }
    return $pkgs[0]
}

# Why the installed Claude needs the patch, or $null when it is patched and healthy.
function Get-RepairReason($Pkg) {
    $asar = Join-Path $Pkg.InstallLocation 'app\resources\app.asar'
    if (-not (Test-Path -LiteralPath $asar)) { return 'app.asar is missing' }
    if ((Get-Item -LiteralPath $asar).Length -eq 0) { return 'app.asar is empty' }
    if (-not (Test-Path -LiteralPath $StateFile)) { return 'no patch state' }
    try { $st = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } catch { return 'patch state unreadable' }
    if ("$($st.patchedVersion)" -ne "$($Pkg.Version)") { return "Claude $($Pkg.Version) is not patched (last: $($st.patchedVersion))" }
    return $null
}

function Invoke-Main {
    $mutex = New-Object Threading.Mutex($false, 'Global\ClaudeRtlRepair')
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { Write-RLog 'Another repair is running - nothing to do.'; return 0 }

        if (-not (Test-StateDirLocked)) {
            Write-RLog "REFUSED: $StateDir is not locked to administrators."
            Write-Status 'refused' '' 'State folder is not admin-only'
            return 3
        }
        if (-not (Test-Path -LiteralPath $PinFile)) {
            Write-RLog 'REFUSED: no pinned public key.'
            Write-Status 'refused' '' 'No pinned public key'
            return 3
        }
        $pin = Get-PinnedRsa

        if ($Refresh) {
            Write-RLog 'Fetching the newest signed patch.ps1 from GitHub...'
            $remote   = Get-RemotePatch
            $newBytes = $remote.Bytes
            $newSig   = $remote.Sig
            if (-not (Test-Signature $pin.Rsa $newBytes $newSig)) {
                Write-RLog 'REFUSED: downloaded patch.ps1 does not match the pinned key.'
                Write-Status 'verify-failed' '' 'Downloaded patch.ps1 failed signature verification'
                return 4
            }
            $haveBuild = [int64]0
            if (Test-Path -LiteralPath $LocalPatch) { $haveBuild = Get-PatchBuild ([IO.File]::ReadAllBytes($LocalPatch)) }
            $newBuild = Get-PatchBuild $newBytes
            if ($newBuild -lt $haveBuild) {
                Write-RLog "REFUSED: GitHub has build $newBuild, older than the local build $haveBuild (rollback)."
                Write-Status 'refused' '' "Older patch build $newBuild than local $haveBuild"
                return 4
            }
            [IO.File]::WriteAllBytes($LocalPatch, $newBytes)
            [IO.File]::WriteAllText($LocalSig, $newSig, (New-Object Text.UTF8Encoding $false))
            Write-RLog "Stored verified patch.ps1 build $newBuild."
        }

        if (-not (Test-Path -LiteralPath $LocalPatch) -or -not (Test-Path -LiteralPath $LocalSig)) {
            Write-RLog 'No local verified patch.ps1 yet - run the Update Claude RTL shortcut once.'
            Write-Status 'needs-refresh' '' 'No local verified patch.ps1'
            return 5
        }
        $bytes = [IO.File]::ReadAllBytes($LocalPatch)
        if (-not (Test-Signature $pin.Rsa $bytes ([IO.File]::ReadAllText($LocalSig)))) {
            Write-RLog 'REFUSED: local patch.ps1 does not match the pinned key.'
            Write-Status 'verify-failed' '' 'Local patch.ps1 failed signature verification'
            return 4
        }

        $pkg = Get-InstalledClaude
        if (-not $pkg) {
            Write-RLog 'Claude (Store/MSIX) is not installed - nothing to patch.'
            Write-Status 'no-claude' '' 'Claude is not installed'
            return 6
        }
        $reason = Get-RepairReason $pkg
        if (-not $reason -and -not $Force) {
            Write-RLog "Claude $($pkg.Version) is already patched - nothing to do."
            Write-Status 'already' "$($pkg.Version)" 'Already patched'
            return 0
        }
        if (-not $reason) { $reason = 'forced re-patch' }
        Write-RLog "Repairing: $reason"

        # Runnable copy: same verified bytes plus the UTF-8 BOM PS 5.1 needs. It is
        # written into the admin-only folder, so nothing unprivileged can swap it.
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
        if (Test-Path -LiteralPath $RunFile) { Remove-Item -LiteralPath $RunFile -Force }
        [IO.File]::WriteAllText($RunFile, $text, (New-Object Text.UTF8Encoding $true))
        if (-not (Test-Path -LiteralPath $WorkTemp)) { New-Item -ItemType Directory -Path $WorkTemp | Out-Null }
        $env:TEMP = $WorkTemp; $env:TMP = $WorkTemp

        $psExe = Join-Path $sys 'WindowsPowerShell\v1.0\powershell.exe'
        # PS 5.1 joins -ArgumentList with plain spaces, so quote the paths here.
        $psArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$RunFile`"",
                  '-Auto', '-Silent', '-ClaudeDir', "`"$($pkg.InstallLocation)`"", '-TrustedPubKey', $pin.B64)
        $proc = Start-Process -FilePath $psExe -ArgumentList $psArgs -WindowStyle Hidden -PassThru
        if (-not $proc.WaitForExit(15 * 60 * 1000)) {
            try { $proc.Kill() } catch {}
            Write-RLog 'Patch run timed out after 15 minutes.'
            Write-Status 'failed' "$($pkg.Version)" 'Timed out'
            return 7
        }
        $code = $proc.ExitCode
        $after = Get-RepairReason $pkg
        if ($code -eq 0 -and -not $after) {
            Write-RLog "RTL patch applied to Claude $($pkg.Version)."
            Write-Status 'ok' "$($pkg.Version)" 'Patched'
            return 0
        }
        Write-RLog "Patch run failed (exit $code; $after). See patch.log."
        Write-Status 'failed' "$($pkg.Version)" "Exit $code; $after"
        return 8
    } catch {
        Write-RLog "Repair error: $($_.Exception.Message)"
        Write-Status 'failed' '' $_.Exception.Message
        return 9
    } finally {
        if (Test-Path -LiteralPath $RunFile) { Remove-Item -LiteralPath $RunFile -Force -ErrorAction SilentlyContinue }
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# Dot-sourcing (tests) loads the functions only.
if ($MyInvocation.InvocationName -ne '.') {
    $rc = Invoke-Main
    if ($Refresh -or $Force) {
        Write-Host ''
        Write-Host 'Press Enter to close this window...'
        $null = Read-Host
    }
    exit $rc
}
