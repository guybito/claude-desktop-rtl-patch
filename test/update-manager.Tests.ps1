# Pester 3 tests for the update manager (src/components). Run:
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester test\update-manager.Tests.ps1"
# Every outside service is simulated: release feed, Claude processes, transcripts,
# Add-AppxPackage, the repair task, toasts and the prompt window.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path (Split-Path -Parent $here) 'src\components'

Describe 'watcher.ps1 - feed and helpers' {
    . (Join-Path $src 'watcher.ps1')

    It 'accepts the real feed shape' {
        $r = ConvertFrom-Feed ([pscustomobject]@{ version = '5.11492.2'; url = 'https://downloads.claude.ai/releases/win32/x64/5.11492.2/Claude-b1edc63367ca6fb5fa8d5a72604951a71b37dd58.msix' })
        $r.Label | Should Be '5.11492.2'
        $r.Version | Should Be ([version]'5.11492.2.0')
    }
    It 'rejects another host, plain http, a version mismatch and junk' {
        $h = 'b1edc63367ca6fb5fa8d5a72604951a71b37dd58'
        ConvertFrom-Feed ([pscustomobject]@{ version = '5.1.2'; url = "https://evil.example/releases/win32/x64/5.1.2/Claude-$h.msix" }) | Should BeNullOrEmpty
        ConvertFrom-Feed ([pscustomobject]@{ version = '5.1.2'; url = "http://downloads.claude.ai/releases/win32/x64/5.1.2/Claude-$h.msix" }) | Should BeNullOrEmpty
        ConvertFrom-Feed ([pscustomobject]@{ version = '5.1.2'; url = "https://downloads.claude.ai/releases/win32/x64/5.1.3/Claude-$h.msix" }) | Should BeNullOrEmpty
        ConvertFrom-Feed ([pscustomobject]@{ version = '5.1.2;calc'; url = "https://downloads.claude.ai/releases/win32/x64/5.1.2/Claude-$h.msix" }) | Should BeNullOrEmpty
        ConvertFrom-Feed ([pscustomobject]@{ version = '5.1.2'; url = "https://downloads.claude.ai/releases/win32/x64/5.1.2/Claude-$h.msix?x=1" }) | Should BeNullOrEmpty
        ConvertFrom-Feed $null | Should BeNullOrEmpty
    }
    It 'reads profile names from Claude command lines' {
        $procs = @(
            [pscustomobject]@{ CommandLine = '"C:\Program Files\WindowsApps\Claude_5.1.0.0_x64__pzs8sxrjxfjjc\app\Claude.exe" ' },
            [pscustomobject]@{ CommandLine = '"C:\...\Claude.exe" --user-data-dir="C:\Users\me\Claude-Work\Claude-Work"' },
            [pscustomobject]@{ CommandLine = '"C:\...\Claude.exe" --user-data-dir="C:\Users\me\Claude-Work\Claude-Work"' },
            [pscustomobject]@{ CommandLine = '"C:\...\Claude.exe" --user-data-dir="C:\x\a&calc\a&calc"' }
        )
        $names = Get-OpenProfiles $procs
        $names.Count | Should Be 2
        $names[0] | Should Be ''
        $names[1] | Should Be 'Claude-Work'
    }
}

Describe 'watcher.ps1 - sessions' {
    . (Join-Path $src 'watcher.ps1')
    $script:FakeNow = [datetime]'2026-11-13T12:00:00'
    $script:Deps.Now = { $script:FakeNow }

    It 'is busy while a transcript was written recently' {
        $script:Deps.NewestTranscript = { $script:FakeNow.AddMinutes(-3) }
        $script:Deps.SessionCpu = { 0.0 }
        (Get-SessionActivity).Idle | Should Be $false
    }
    It 'is busy when session processes use CPU' {
        $script:Deps.NewestTranscript = { $script:FakeNow.AddMinutes(-30) }
        $script:Deps.SessionCpu = { 4.0 }
        (Get-SessionActivity).Idle | Should Be $false
    }
    It 'is idle when quiet and cold' {
        $script:Deps.NewestTranscript = { $script:FakeNow.AddMinutes(-30) }
        $script:Deps.SessionCpu = { 0.2 }
        (Get-SessionActivity).Idle | Should Be $true
    }
    It 'is idle when there are no transcripts at all' {
        $script:Deps.NewestTranscript = { $null }
        $script:Deps.SessionCpu = { 0.0 }
        (Get-SessionActivity).Idle | Should Be $true
    }
}

Describe 'watcher.ps1 - update manager end to end (simulated)' {
    . (Join-Path $src 'watcher.ps1')
    $tmp = Join-Path $env:TEMP ("rtl-um-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $script:UserDir = $tmp
    $script:UserState = Join-Path $tmp 'update-manager.json'
    $script:ChoiceFile = Join-Path $tmp 'update-choice.json'
    $script:LogFile = Join-Path $tmp 'watcher.log'
    $script:ProgressFile = Join-Path $tmp 'update-progress.json'

    $url = 'https://downloads.claude.ai/releases/win32/x64/5.20000.1/Claude-b1edc63367ca6fb5fa8d5a72604951a71b37dd58.msix'
    function Reset-World {
        $script:FakeNow = [datetime]'2026-11-13T12:00:00'
        $script:Installed = [version]'5.11492.2.0'
        $script:Busy = $false
        $script:Stuck = $false
        $script:AddFails = 0
        $script:RepairResult = 'ok'
        $script:Log = New-Object System.Collections.Generic.List[string]
        Remove-Item $script:ChoiceFile -ErrorAction SilentlyContinue
        $script:Deps.Now = { $script:FakeNow }
        $script:Deps.GetInstalledVer = { $script:Installed }
        $script:Deps.GetFeed = { [pscustomobject]@{ version = '5.20000.1'; url = $url } }
        $script:Deps.NewestTranscript = { if ($script:Busy) { $script:FakeNow.AddMinutes(-1) } else { $script:FakeNow.AddHours(-2) } }
        $script:Deps.SessionCpu = { 0.0 }
        $script:Deps.ClaudeMainProcs = { @([pscustomobject]@{ CommandLine = 'Claude.exe' }, [pscustomobject]@{ CommandLine = 'Claude.exe --user-data-dir="C:\Users\g\Claude-Work\Claude-Work"' }) }
        $script:Deps.ShowPrompt = { param($n, $c) $script:Log.Add("prompt $n $c") }
        $script:Deps.Toast = { param($t, $b) $script:Log.Add("toast $t") }
        $script:Deps.StopClaude = { $script:Log.Add('stop') }
        $script:Deps.AddPackage = { param($u, $onProgress)
            if ($script:AddFails -gt 0) { $script:AddFails--; throw 'apps need to be closed' }
            if ($onProgress) { & $onProgress 40; $script:MidInstall = Get-Content $script:ProgressFile -Raw | ConvertFrom-Json }
            $script:Log.Add("add $u"); $script:Installed = [version]'5.20000.1.0' }
        $script:Deps.ShowProgress = { param($v) $script:Log.Add("progress $v") }
        $script:MidInstall = $null
        $script:Deps.RunRepair = { $script:Log.Add('repair'); @{ Result = $script:RepairResult; Message = '' } }
        $script:Deps.StartProfiles = { param($p) $script:Log.Add('start ' + (@($p) -join '|')) }
        $script:Deps.StuckSignal = { $script:Stuck }
        $script:Deps.Sleep = { param($s) }
    }
    function New-State { Read-ManagerState }
    function Set-Choice([string]$Mode, $At = $null, $Until = $null) {
        @{ version = '5.20000.1'; mode = $Mode; at = $At; snoozeUntil = $Until } | ConvertTo-Json | Set-Content $script:ChoiceFile
    }

    It 'offers a newer version once, and again only after 4 hours' {
        Reset-World
        $s = Invoke-ManagerTick (New-State)
        $s.pendingVersion | Should Be '5.20000.1'
        $s.mode | Should Be 'ask'
        ($script:Log | Where-Object { $_ -like 'prompt*' }).Count | Should Be 1
        $script:FakeNow = $script:FakeNow.AddHours(1)
        $s = Invoke-ManagerTick $s
        ($script:Log | Where-Object { $_ -like 'prompt*' }).Count | Should Be 1
        $script:FakeNow = $script:FakeNow.AddHours(4)
        $s = Invoke-ManagerTick $s
        ($script:Log | Where-Object { $_ -like 'prompt*' }).Count | Should Be 2
    }

    It '"now" with no session: stops, installs, repairs, reopens both profiles' {
        Reset-World
        $s = Invoke-ManagerTick (New-State)
        Set-Choice 'now'
        $s = Invoke-ManagerTick $s
        ($script:Log -join ';') | Should Match 'stop;add https://downloads\.claude\.ai/.*;repair;start \|Claude-Work'
        $s.pendingVersion | Should BeNullOrEmpty
        $s.lastResult | Should Be 'ok'
        Test-Path $script:ChoiceFile | Should Be $false
    }

    It '"now" while a session works: waits, tells the user, then updates when it ends' {
        Reset-World
        $s = Invoke-ManagerTick (New-State)
        Set-Choice 'now'
        $script:Busy = $true
        $s = Invoke-ManagerTick $s
        ($script:Log | Where-Object { $_ -like 'add*' }).Count | Should Be 0
        ($script:Log | Where-Object { $_ -like 'toast*' }).Count | Should Be 1
        $s.mode | Should Be 'idle'
        $script:FakeNow = $script:FakeNow.AddMinutes(5)
        $s = Invoke-ManagerTick $s
        ($script:Log | Where-Object { $_ -like 'toast*' }).Count | Should Be 1   # told once
        $script:Busy = $false
        $script:FakeNow = $script:FakeNow.AddMinutes(5)
        $s = Invoke-ManagerTick $s
        ($script:Log | Where-Object { $_ -like 'add*' }).Count | Should Be 1
        $s.pendingVersion | Should BeNullOrEmpty
    }

    It '"at" waits for the time, then still waits for sessions' {
        Reset-World
        $s = Invoke-ManagerTick (New-State)
        Set-Choice 'at' ($script:FakeNow.AddHours(3).ToString('o'))
        $s = Invoke-ManagerTick $s
        $s.mode | Should Be 'at'
        ($script:Log | Where-Object { $_ -like 'add*' }).Count | Should Be 0
        $script:FakeNow = $script:FakeNow.AddHours(3).AddMinutes(1)
        $script:Busy = $true
        $s = Invoke-ManagerTick $s
        ($script:Log | Where-Object { $_ -like 'add*' }).Count | Should Be 0
        $s.mode | Should Be 'idle'
        $script:Busy = $false
        $s = Invoke-ManagerTick $s
        ($script:Log | Where-Object { $_ -like 'add*' }).Count | Should Be 1
    }

    It '"snooze" stays quiet until the next morning, then asks again' {
        Reset-World
        $s = Invoke-ManagerTick (New-State)
        Set-Choice 'snooze' $null ($script:FakeNow.Date.AddDays(1).AddHours(9).ToString('o'))
        $s = Invoke-ManagerTick $s
        $script:FakeNow = $script:FakeNow.AddHours(6)
        $s = Invoke-ManagerTick $s
        ($script:Log | Where-Object { $_ -like 'prompt*' }).Count | Should Be 1
        $script:FakeNow = [datetime]'2026-11-14T09:05:00'
        $s = Invoke-ManagerTick $s
        ($script:Log | Where-Object { $_ -like 'prompt*' }).Count | Should Be 2
    }

    It 'ignores an answer for a different version' {
        Reset-World
        $s = Invoke-ManagerTick (New-State)
        @{ version = '9.9.9'; mode = 'now' } | ConvertTo-Json | Set-Content $script:ChoiceFile
        $s = Invoke-ManagerTick $s
        $s.mode | Should Be 'ask'
        ($script:Log | Where-Object { $_ -like 'add*' }).Count | Should Be 0
    }

    It 'clears the offer when Claude already has that version' {
        Reset-World
        $s = Invoke-ManagerTick (New-State)
        $script:Installed = [version]'5.20000.1.0'
        $script:FakeNow = $script:FakeNow.AddHours(2)
        $s = Invoke-ManagerTick $s
        $s.pendingVersion | Should BeNullOrEmpty
    }

    It 'ignores a feed answer it does not recognize' {
        Reset-World
        $script:Deps.GetFeed = { [pscustomobject]@{ version = '6.0.0'; url = 'https://evil.example/x.msix' } }
        $s = Invoke-ManagerTick (New-State)
        $s.pendingVersion | Should BeNullOrEmpty
    }

    It 'when Windows refuses the install twice: reopens Claude and keeps the offer' {
        Reset-World
        $s = Invoke-ManagerTick (New-State)
        Set-Choice 'now'
        $script:AddFails = 2
        $s = Invoke-ManagerTick $s
        $s.lastResult | Should Be 'install-failed'
        $s.pendingVersion | Should Be '5.20000.1'
        ($script:Log | Where-Object { $_ -like 'start*' }).Count | Should Be 1
        ($script:Log | Where-Object { $_ -eq 'repair' }).Count | Should Be 0
    }

    It 'shows the progress window and reports each stage to it' {
        Reset-World
        $s = Invoke-ManagerTick (New-State)
        Set-Choice 'now'
        $s = Invoke-ManagerTick $s
        $script:Log[1] | Should Be 'progress 5.20000.1'       # window opens before Claude closes
        $script:Log[2] | Should Be 'stop'
        $script:MidInstall.stages[$script:MidInstall.stageIndex].name | Should Be 'install'
        $script:MidInstall.stagePercent | Should Be 40
        $script:MidInstall.status | Should Be 'running'
        $script:MidInstall.pid | Should Be $PID
        $end = Get-Content $script:ProgressFile -Raw | ConvertFrom-Json
        $end.status | Should Be 'done'
        $end.stages[$end.stageIndex].name | Should Be 'open'
        Test-Path "$script:ProgressFile.tmp" | Should Be $false
    }

    It 'learns stage times from a finished update and keeps them across restarts' {
        Reset-World
        $s = Invoke-ManagerTick (New-State)
        Set-Choice 'now'
        $s = Invoke-ManagerTick $s
        $s.stageSecs.install | Should Be 75                    # (150 + ~0) / 2
        Save-ManagerState $s
        $est = Get-StageEstimates (Read-ManagerState)
        $est.install | Should Be 75
        $est.close | Should Be 5
        (Get-StageEstimates @{ stageSecs = $null }).install | Should Be 150
        (Get-StageEstimates @{ stageSecs = @{ install = 99999 } }).install | Should Be 1800
        Remove-Item $script:UserState
    }

    It 'marks the progress as failed when Windows refuses the install' {
        Reset-World
        $s = Invoke-ManagerTick (New-State)
        Set-Choice 'now'
        $script:AddFails = 2
        $s = Invoke-ManagerTick $s
        (Get-Content $script:ProgressFile -Raw | ConvertFrom-Json).status | Should Be 'failed'
        $s.stageSecs | Should BeNullOrEmpty                    # a failed run teaches nothing
    }

    It 'reports a failed RTL repair but still reopens Claude' {
        Reset-World
        $s = Invoke-ManagerTick (New-State)
        Set-Choice 'now'
        $script:RepairResult = 'failed'
        $s = Invoke-ManagerTick $s
        $s.lastResult | Should Be 'repair-failed'
        ($script:Log | Where-Object { $_ -like 'start*' }).Count | Should Be 1
    }

    It 'a frozen Claude on a waiting update is finished once sessions are idle' {
        Reset-World
        $script:Stuck = $true
        $script:Busy = $true
        $s = New-State
        $s.lastCheck = $script:FakeNow.ToString('o')     # no regular feed check this tick
        $s = Invoke-ManagerTick $s
        $s.mode | Should Be 'idle'
        ($script:Log | Where-Object { $_ -like 'add*' }).Count | Should Be 0
        $script:Busy = $false
        $s = Invoke-ManagerTick $s
        ($script:Log | Where-Object { $_ -like 'add*' }).Count | Should Be 1
    }

    It 'survives a state file it cannot read' {
        Reset-World
        Set-Content $script:UserState '{not json'
        $s = Read-ManagerState
        $s.pendingVersion | Should BeNullOrEmpty
        Remove-Item $script:UserState
    }

    It 'starts the repair task only for an unpatched newer Claude, throttled' {
        Reset-World
        $sf = Join-Path $tmp 'state.json'
        @{ patchedVersion = '5.11492.2.0' } | ConvertTo-Json | Set-Content $sf
        $script:StateFile = $sf
        $script:LastRepairStart = [datetime]::MinValue
        Test-AndRepair 'C:\Program Files\WindowsApps\Claude_5.11492.2.0_x64__pzs8sxrjxfjjc\app\claude.exe'
        ($script:Log | Where-Object { $_ -eq 'repair' }).Count | Should Be 0
        Test-AndRepair 'C:\Program Files\WindowsApps\Claude_5.20000.1.0_x64__pzs8sxrjxfjjc\app\claude.exe'
        Test-AndRepair 'C:\Program Files\WindowsApps\Claude_5.20000.1.0_x64__pzs8sxrjxfjjc\app\claude.exe'
        ($script:Log | Where-Object { $_ -eq 'repair' }).Count | Should Be 1
    }

    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'update-prompt.ps1 - choices' {
    . (Join-Path $src 'update-prompt.ps1') -NewVersion '5.20000.1'
    It 'defaults the time picker to the next 02:00' {
        (Get-NextAt ([datetime]'2026-11-13T12:00') 2) | Should Be ([datetime]'2026-11-14T02:00')
        (Get-NextAt ([datetime]'2026-11-13T01:00') 2) | Should Be ([datetime]'2026-11-13T02:00')
    }
    It 'writes the right fields per choice' {
        $n = [datetime]'2026-11-13T12:00'
        (New-Choice 'now' $n $null).mode | Should Be 'now'
        (New-Choice 'at' $n ([datetime]'2026-11-14T02:00')).at | Should Match '^2026-11-14T02:00'
        (New-Choice 'snooze' $n $null).snoozeUntil | Should Match '^2026-11-14T09:00'
        (New-Choice 'idle' $n $null).version | Should Be '5.20000.1'
    }
}

Describe 'update-progress.ps1 - what the window shows' {
    . (Join-Path $src 'update-progress.ps1')
    $t0 = [datetime]'2026-11-15T12:00:00'
    function P($Index, [int]$AgoSec, $Pct = $null, $Status = 'running') {
        [pscustomobject]@{ status = $Status; stageIndex = $Index; stagePercent = $Pct
            stageStart = $t0.AddSeconds(-$AgoSec).ToString('o')
            stages = @([pscustomobject]@{ name = 'close'; est = 10 }, [pscustomobject]@{ name = 'install'; est = 150 },
                       [pscustomobject]@{ name = 'rtl'; est = 90 }, [pscustomobject]@{ name = 'open'; est = 20 }) }
    }
    It 'starts at 0% with the whole estimate left' {
        $v = Get-ProgressView (P 0 0) $t0
        $v.Percent | Should Be 0; $v.SecondsLeft | Should Be 270; $v.Step | Should Be 1; $v.Steps | Should Be 4
    }
    It 'moves with time inside a stage but never past it' {
        (Get-ProgressView (P 2 45) $t0).Percent | Should Be 76       # (160 + 45) / 270
        $late = Get-ProgressView (P 2 900) $t0
        $late.Percent | Should Be 91                                  # capped at 95% of the stage
        $late.SecondsLeft | Should Be 25                              # 5 s floor + the open stage
    }
    It 'uses the real install percent once Windows reports at least 5%' {
        $v = Get-ProgressView (P 1 60 50) $t0
        $v.Percent | Should Be 31                                     # (10 + 75) / 270
        $v.SecondsLeft | Should Be 170                                # 60 more s + 110 for the rest
        (Get-ProgressView (P 1 60 2) $t0).SecondsLeft | Should Be 200 # below 5%: time-based
    }
    It 'shows 100% when the update ended, either way' {
        (Get-ProgressView (P 3 1 $null 'done') $t0).Percent | Should Be 100
        (Get-ProgressView (P 1 1 $null 'failed') $t0).SecondsLeft | Should Be 0
    }
    It 'words the time left' {
        Format-TimeLeft 8 | Should Be (Heb 'Claude ייפתח בעוד כמה שניות')
        Format-TimeLeft 45 | Should Be (Heb 'Claude ייפתח בעוד פחות מדקה')
        Format-TimeLeft 60 | Should Be (Heb 'Claude ייפתח בעוד כדקה')
        Format-TimeLeft 170 | Should Be ((Heb 'Claude ייפתח בעוד כ-') + '3' + (Heb ' דקות'))
    }
}

Describe 'watcher.ps1 - real Add-AppxPackage wrapper' {
    . (Join-Path $src 'watcher.ps1')
    It 'throws when the package cannot be installed, so the retry logic sees it' {
        $missing = Join-Path $env:TEMP ("no-such-" + [guid]::NewGuid().ToString('N') + '.msix')
        { Add-PackageWithProgress $missing { } } | Should Throw
    }
}

Describe 'repair.ps1 - protected runner' {
    $savedPath = $env:PATH; $savedMod = $env:PSModulePath
    . (Join-Path $src 'repair.ps1')
    $env:PATH = $savedPath; $env:PSModulePath = $savedMod
    $RealLocked = ${function:Test-StateDirLocked}

    $tmp = Join-Path $env:TEMP ("rtl-rp-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $StateDir = $tmp
    $PinFile = Join-Path $tmp 'trusted-pubkey.b64'; $LocalPatch = Join-Path $tmp 'patch-local.ps1'
    $LocalSig = Join-Path $tmp 'patch-local.ps1.sig'; $RunFile = Join-Path $tmp 'patch-run.ps1'
    $StatusFile = Join-Path $tmp 'repair-status.json'; $StateFile = Join-Path $tmp 'state.json'
    $LogFile = Join-Path $tmp 'repair.log'; $WorkTemp = Join-Path $tmp 'tmp'

    # Test key pair and a signed "patch".
    $key = New-Object Security.Cryptography.RSACryptoServiceProvider 2048
    $pub = $key.ExportParameters($false)
    $pinJson = @{ Modulus = [Convert]::ToBase64String($pub.Modulus); Exponent = [Convert]::ToBase64String($pub.Exponent) } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($PinFile, [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pinJson)))
    function Sign([byte[]]$b) { [Convert]::ToBase64String($key.SignData($b, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)) }
    function New-PatchBytes([int64]$Build) { [Text.Encoding]::UTF8.GetBytes("param()`n`$script:PatchBuild = $Build`nexit 0`n") }

    $claudeDir = Join-Path $tmp 'Claude_5.20000.1.0_x64__pzs8sxrjxfjjc'
    New-Item -ItemType Directory -Path (Join-Path $claudeDir 'app\resources') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $claudeDir 'app\resources\app.asar'), 'asar')
    $script:Pkg = [pscustomobject]@{ Version = '5.20000.1.0'; InstallLocation = $claudeDir }

    function Test-StateDirLocked { $script:Locked }
    function Get-InstalledClaude { $script:Pkg }
    function Start-Process {
        param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru)
        $script:Launched = $ArgumentList -join ' '
        if ($script:PatchSucceeds) { @{ patchedVersion = '5.20000.1.0' } | ConvertTo-Json | Set-Content $StateFile }
        $p = New-Object psobject
        $p | Add-Member ScriptMethod WaitForExit { param($ms) $true }
        $p | Add-Member NoteProperty ExitCode $(if ($script:PatchSucceeds) { 0 } else { 1 })
        $p | Add-Member ScriptMethod Kill { }
        return $p
    }
    function Get-RemotePatch { $script:Remote }
    function Reset {
        $script:Locked = $true; $script:PatchSucceeds = $true; $script:Launched = $null
        $Refresh = $false; $Force = $false
        Remove-Item $StateFile, $LocalPatch, $LocalSig, $StatusFile -ErrorAction SilentlyContinue
    }
    function Status { (Get-Content $StatusFile -Raw | ConvertFrom-Json).result }

    It 'refuses when the state folder is not admin-only' {
        Reset; $script:Locked = $false
        Invoke-Main | Should Be 3
        Status | Should Be 'refused'
    }
    It 'needs a refresh when there is no local verified copy' {
        Reset
        Invoke-Main | Should Be 5
    }
    It 'refuses a local copy whose signature does not match' {
        Reset
        [IO.File]::WriteAllBytes($LocalPatch, (New-PatchBytes 2026111301))
        [IO.File]::WriteAllText($LocalSig, (Sign (New-PatchBytes 1)))
        Invoke-Main | Should Be 4
        Status | Should Be 'verify-failed'
        $script:Launched | Should BeNullOrEmpty
    }
    It 'does nothing (and closes nothing) when Claude is already patched' {
        Reset
        $b = New-PatchBytes 2026111301
        [IO.File]::WriteAllBytes($LocalPatch, $b); [IO.File]::WriteAllText($LocalSig, (Sign $b))
        @{ patchedVersion = '5.20000.1.0' } | ConvertTo-Json | Set-Content $StateFile
        Invoke-Main | Should Be 0
        Status | Should Be 'already'
        $script:Launched | Should BeNullOrEmpty
    }
    It 'patches an unpatched Claude from the admin-only copy, then removes the run file' {
        Reset
        $b = New-PatchBytes 2026111301
        [IO.File]::WriteAllBytes($LocalPatch, $b); [IO.File]::WriteAllText($LocalSig, (Sign $b))
        Invoke-Main | Should Be 0
        Status | Should Be 'ok'
        $script:Launched | Should Match ([regex]::Escape("`"$RunFile`""))
        $script:Launched | Should Match '-Silent'
        $script:Launched | Should Match ([regex]::Escape("-ClaudeDir `"$claudeDir`""))
        Test-Path $RunFile | Should Be $false
    }
    It 'reports a failed patch run' {
        Reset; $script:PatchSucceeds = $false
        $b = New-PatchBytes 2026111301
        [IO.File]::WriteAllBytes($LocalPatch, $b); [IO.File]::WriteAllText($LocalSig, (Sign $b))
        Invoke-Main | Should Be 8
        Status | Should Be 'failed'
    }
    It 'refresh: refuses an older (rollback) build even when correctly signed' {
        Reset
        $b = New-PatchBytes 2026111301
        [IO.File]::WriteAllBytes($LocalPatch, $b); [IO.File]::WriteAllText($LocalSig, (Sign $b))
        $old = New-PatchBytes 2026010100
        $script:Remote = @{ Bytes = $old; Sig = (Sign $old) }
        $Refresh = $true
        Invoke-Main | Should Be 4
        [IO.File]::ReadAllBytes($LocalPatch).Length | Should Be $b.Length
    }
    It 'refresh: refuses a download with a bad signature' {
        Reset
        $new = New-PatchBytes 2026120100
        $script:Remote = @{ Bytes = $new; Sig = (Sign (New-PatchBytes 5)) }
        $Refresh = $true
        Invoke-Main | Should Be 4
        Test-Path $LocalPatch | Should Be $false
    }
    It 'refresh: stores a newer signed build and applies it' {
        Reset
        $new = New-PatchBytes 2026120100
        $script:Remote = @{ Bytes = $new; Sig = (Sign $new) }
        $Refresh = $true
        Invoke-Main | Should Be 0
        Get-PatchBuild ([IO.File]::ReadAllBytes($LocalPatch)) | Should Be 2026120100
    }
    It 'reads build numbers, and treats a missing one as 0' {
        Get-PatchBuild (New-PatchBytes 42) | Should Be 42
        Get-PatchBuild ([Text.Encoding]::UTF8.GetBytes('no build here')) | Should Be 0
    }
    It 'Test-StateDirLocked rejects a user-owned folder' {
        & $RealLocked | Should Be $false
    }

    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
