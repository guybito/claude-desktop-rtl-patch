# Claude RTL Patch -- watcher and update manager (watcher.ps1).
#
# Runs at logon as the signed-in user WITHOUT admin rights (scheduled task
# "ClaudeRtlPatchWatcher", RunLevel Limited). Two jobs:
#   1. When a new claude.exe version starts and it is not RTL-patched yet, start the
#      protected "ClaudeRtlPatchRepair" task (SYSTEM). That task takes no input and
#      only runs the locally verified patch.ps1, so nothing here can steer it.
#   2. Update manager. Claude's own updater is switched off by policy because on the
#      MSIX build it freezes the app after downloading an update. Instead, every hour
#      this checks Anthropic's release feed; when a newer Claude exists it asks the
#      user: update now / when all sessions are finished / at a set time / tomorrow.
#      Before any update it checks that no Claude Code session is working, closes
#      every Claude profile, installs the update, has the RTL re-applied and reopens
#      the profiles that were open. It also unsticks an update that Windows left
#      waiting while Claude froze.
#
# Text shown to the user is Hebrew and appears only inside (Heb '...') calls; the build
# turns those characters into \u escapes so patch.ps1 stays ASCII.

$ErrorActionPreference = 'Continue'

$script:StateDir     = Join-Path $env:ProgramData 'ClaudeRtlPatch'
$script:StateFile    = Join-Path $script:StateDir 'state.json'
$script:RepairStatus = Join-Path $script:StateDir 'repair-status.json'
$script:PromptScript = Join-Path $script:StateDir 'update-prompt.ps1'
$script:UserDir      = Join-Path $env:LOCALAPPDATA 'ClaudeRtlPatch'
$script:UserState    = Join-Path $script:UserDir 'update-manager.json'
$script:ChoiceFile   = Join-Path $script:UserDir 'update-choice.json'
$script:LogFile      = Join-Path $script:UserDir 'watcher.log'
$script:ProgressFile   = Join-Path $script:UserDir 'update-progress.json'
$script:ProgressScript = Join-Path $script:StateDir 'update-progress.ps1'
# First-run seconds per update stage; afterwards learned from real updates.
$script:DefaultStageSecs = [ordered]@{ close = 10; install = 150; rtl = 90; open = 20 }
$script:RepairTask   = 'ClaudeRtlPatchRepair'
$script:FeedUrl      = 'https://api.anthropic.com/api/desktop/win32/x64/msix/latest'
$script:CheckEveryMin      = 60
$script:RepromptAfterHours = 4
$script:QuietMinutes       = 10     # no Claude Code transcript written for this long
$script:BusyCpuSeconds     = 1.5    # CPU used by session processes in the sample window
$script:CpuSampleSeconds   = 15
$script:StuckLogMinutes    = 5
$script:LauncherVbs  = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude-Launcher.vbs'
$script:TranscriptRoots = @(Join-Path $env:USERPROFILE '.claude\projects')

function Heb([string]$s) { return [regex]::Unescape($s) }

function Write-WLog([string]$msg) {
    try {
        if (-not (Test-Path $script:UserDir)) { New-Item -ItemType Directory -Path $script:UserDir -Force | Out-Null }
        if ((Test-Path $script:LogFile) -and (Get-Item $script:LogFile).Length -gt 1MB) {
            Move-Item $script:LogFile "$script:LogFile.old" -Force
        }
        "$([DateTime]::Now.ToString('o'))  $msg" | Out-File -Append -FilePath $script:LogFile -Encoding UTF8
    } catch {}
}

# ---------------------------------------------------------------------------
# Side effects behind one table, so tests can replace each of them.
# ---------------------------------------------------------------------------
$script:Deps = @{
    Now               = { Get-Date }
    GetInstalledVer   = { Get-InstalledClaudeVersion }
    GetFeed           = { Invoke-RestMethod -Uri $script:FeedUrl -UseBasicParsing -TimeoutSec 20 }
    NewestTranscript  = { Get-NewestTranscriptTime }
    SessionCpu        = { Measure-SessionCpu }
    ClaudeMainProcs   = { Get-ClaudeMainProcesses }
    ShowPrompt        = { param($new, $cur) Show-UpdatePrompt $new $cur }
    Toast             = { param($title, $body) Show-Toast $title $body }
    StopClaude        = { Stop-AllClaude }
    AddPackage        = { param($url, $onProgress) Add-PackageWithProgress $url $onProgress }
    ShowProgress      = { param($ver) Show-UpdateProgress $ver }
    RunRepair         = { Invoke-RepairTask }
    StartProfiles     = { param($profiles) Start-ClaudeProfiles $profiles }
    StuckSignal       = { Test-UpdateStuck }
    Sleep             = { param($s) Start-Sleep -Seconds $s }
}

# ---------------------------------------------------------------------------
# Versions and the release feed
# ---------------------------------------------------------------------------
function ConvertTo-Version([string]$Text) {
    if (-not $Text -or $Text -notmatch '^\d+(\.\d+){1,3}$') { return $null }
    $parts = @($Text.Split('.'))
    while ($parts.Count -lt 4) { $parts += '0' }
    return [version]($parts[0..3] -join '.')
}

function Get-InstalledClaudeVersion {
    $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue |
        Where-Object { $_.InstallLocation -like '*\WindowsApps\Claude_*' } |
        Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    if ($pkg) { return [version]$pkg.Version }
    return $null
}

# Accepts only the shape Anthropic's feed returns, with the download on
# downloads.claude.ai over HTTPS for exactly that version. Anything else is ignored.
function ConvertFrom-Feed($Obj) {
    if (-not $Obj) { return $null }
    $ver = "$($Obj.version)"
    $url = "$($Obj.url)"
    if ($ver -notmatch '^\d+\.\d+\.\d+$') { return $null }
    $esc = [regex]::Escape($ver)
    if ($url -notmatch "^https://downloads\.claude\.ai/releases/win32/x64/$esc/Claude-[0-9a-f]{40}\.msix$") { return $null }
    return @{ Version = (ConvertTo-Version $ver); Label = $ver; Url = $url }
}

# ---------------------------------------------------------------------------
# User state (LocalAppData; unprivileged on purpose)
# ---------------------------------------------------------------------------
function Read-ManagerState {
    $default = @{ pendingVersion = $null; pendingUrl = $null; mode = $null; at = $null; snoozeUntil = $null;
                  promptedAt = $null; lastCheck = $null; busyNotified = $false; lastResult = $null; stageSecs = $null }
    if (-not (Test-Path -LiteralPath $script:UserState)) { return $default }
    try {
        $o = Get-Content -LiteralPath $script:UserState -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($default.Keys)) { if ($o.PSObject.Properties[$k]) { $default[$k] = $o.$k } }
    } catch { Write-WLog "State unreadable, starting fresh: $($_.Exception.Message)" }
    return $default
}

function Save-ManagerState($State) {
    try {
        if (-not (Test-Path $script:UserDir)) { New-Item -ItemType Directory -Path $script:UserDir -Force | Out-Null }
        $State | ConvertTo-Json | Set-Content -LiteralPath $script:UserState -Encoding UTF8
    } catch { Write-WLog "State save failed: $($_.Exception.Message)" }
}

# Applies the answer the prompt window left behind, then removes it.
function Merge-PromptChoice($State) {
    if (-not (Test-Path -LiteralPath $script:ChoiceFile)) { return $State }
    try {
        $c = Get-Content -LiteralPath $script:ChoiceFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ("$($c.version)" -eq "$($State.pendingVersion)" -and "$($c.mode)" -in @('now', 'idle', 'at', 'snooze')) {
            $State.mode = "$($c.mode)"
            $State.at = $c.at
            $State.snoozeUntil = $c.snoozeUntil
            $State.busyNotified = $false
            Write-WLog "User chose '$($State.mode)' for Claude $($State.pendingVersion)."
        }
    } catch { Write-WLog "Prompt answer unreadable: $($_.Exception.Message)" }
    Remove-Item -LiteralPath $script:ChoiceFile -Force -ErrorAction SilentlyContinue
    return $State
}

function ConvertTo-Date($Value) {
    if (-not $Value) { return $null }
    try { return [datetime]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind) } catch { return $null }
}

# ---------------------------------------------------------------------------
# Are Claude Code sessions working right now?
# ---------------------------------------------------------------------------
function Get-NewestTranscriptTime {
    $newest = $null
    foreach ($root in $script:TranscriptRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $f = Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($f -and (-not $newest -or $f.LastWriteTime -gt $newest)) { $newest = $f.LastWriteTime }
    }
    return $newest
}

# CPU seconds used during the sample window by Claude Code processes and every
# process they started (shells, builds, tests, MCP servers).
function Measure-SessionCpu {
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $roots = @($all | Where-Object { $_.Name -eq 'claude.exe' -and $_.ExecutablePath -like '*\claude-code\*' })
    if ($roots.Count -eq 0) { return 0.0 }
    $ids = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($r in $roots) { [void]$ids.Add([int]$r.ProcessId) }
    $grew = $true
    while ($grew) {
        $grew = $false
        foreach ($p in $all) {
            if ($ids.Contains([int]$p.ParentProcessId) -and $ids.Add([int]$p.ProcessId)) { $grew = $true }
        }
    }
    $cpu = {
        $sum = 0.0
        foreach ($id in $ids) { $p = Get-Process -Id $id -ErrorAction SilentlyContinue; if ($p) { $sum += $p.TotalProcessorTime.TotalSeconds } }
        $sum
    }
    $a = & $cpu
    Start-Sleep -Seconds $script:CpuSampleSeconds
    $b = & $cpu
    return [Math]::Max(0.0, $b - $a)
}

function Get-SessionActivity {
    $now = & $script:Deps.Now
    $newest = & $script:Deps.NewestTranscript
    if ($newest -and ($now - $newest).TotalMinutes -lt $script:QuietMinutes) {
        return @{ Idle = $false; Reason = "a Claude Code session wrote $([int]($now - $newest).TotalMinutes) min ago" }
    }
    $cpu = & $script:Deps.SessionCpu
    if ($cpu -ge $script:BusyCpuSeconds) {
        return @{ Idle = $false; Reason = ("Claude Code processes are busy ({0:N1}s CPU)" -f $cpu) }
    }
    return @{ Idle = $true; Reason = 'no active session' }
}

# ---------------------------------------------------------------------------
# Claude processes and profiles
# ---------------------------------------------------------------------------
function Get-ClaudeMainProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -like '*\WindowsApps\Claude_*' -and $_.CommandLine -notmatch '\s--type=' })
}

# Profile name of each open Claude window process: '' for the default profile,
# otherwise the folder name the launcher uses (--user-data-dir=<home>\<P>\<P>).
function Get-OpenProfiles($Procs) {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($Procs)) {
        $cl = "$($p.CommandLine)"
        $name = ''
        $m = [regex]::Match($cl, '--user-data-dir="?([^"]+?)"?(\s|$)')
        if ($m.Success) { $name = Split-Path -Leaf $m.Groups[1].Value.TrimEnd('\') }
        if ($name -notmatch '^[A-Za-z0-9 _.-]*$') { continue }
        if (-not $names.Contains($name)) { $names.Add($name) }
    }
    return ,$names.ToArray()
}

function Stop-AllClaude {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue)
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
}

function Start-ClaudeProfiles($Profiles) {
    $list = @($Profiles)
    if ($list.Count -eq 0) { $list = @('') }
    foreach ($name in $list) {
        if (Test-Path -LiteralPath $script:LauncherVbs) {
            Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList "`"$script:LauncherVbs`" `"$name`""
        } elseif (-not $name) {
            Start-Process 'shell:AppsFolder\Claude_pzs8sxrjxfjjc!Claude'
        }
        Start-Sleep -Seconds 4
    }
}

# Starts the protected repair task and waits for its verdict.
function Invoke-RepairTask {
    $before = (Get-Date).ToUniversalTime()
    try { Start-ScheduledTask -TaskName $script:RepairTask -ErrorAction Stop }
    catch { return @{ Result = 'no-task'; Message = $_.Exception.Message } }
    $deadline = (Get-Date).AddMinutes(16)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        try {
            $s = Get-Content -LiteralPath $script:RepairStatus -Raw | ConvertFrom-Json
            $at = ConvertTo-Date $s.at
            if ($at -and $at.ToUniversalTime() -gt $before) { return @{ Result = "$($s.result)"; Message = "$($s.message)" } }
        } catch {}
    }
    return @{ Result = 'timeout'; Message = 'The repair task did not report back within 16 minutes' }
}

# Claude froze after staging an update: its main process is alive, Windows keeps a
# newer Claude waiting for it to close, and no Claude log has moved for a while.
function Test-UpdateStuck {
    $procs = @(Get-ClaudeMainProcesses)
    if ($procs.Count -eq 0) { return $false }
    $installed = Get-InstalledClaudeVersion
    if (-not $installed) { return $false }
    $since = (Get-Date).AddHours(-12)
    $waiting = $false
    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-AppXDeploymentServer/Operational'; Id = 658; StartTime = $since } -ErrorAction Stop
        foreach ($e in $events) {
            if ($e.Message -match 'Claude_(\d+(?:\.\d+){3})_x64__pzs8sxrjxfjjc\} for deferred') {
                if ([version]$Matches[1] -gt $installed) { $waiting = $true; break }
            }
        }
    } catch {}
    if (-not $waiting) { return $false }
    $logs = @(Join-Path $env:LOCALAPPDATA 'Claude\Logs\main.log')
    foreach ($p in $procs) {
        $m = [regex]::Match("$($p.CommandLine)", '--user-data-dir="?([^"]+?)"?(\s|$)')
        if ($m.Success) { $logs += Join-Path $m.Groups[1].Value 'logs\main.log' }
    }
    $fresh = (Get-Date).AddMinutes(-$script:StuckLogMinutes)
    foreach ($l in $logs) {
        if ((Test-Path -LiteralPath $l) -and (Get-Item -LiteralPath $l).LastWriteTime -gt $fresh) { return $false }
    }
    return $true
}

# ---------------------------------------------------------------------------
# User interface
# ---------------------------------------------------------------------------
function Show-Toast([string]$Title, [string]$Body) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $t = [Security.SecurityElement]::Escape($Title)
        $b = [Security.SecurityElement]::Escape($Body)
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$t</text><text>$b</text></binding></visual></toast>")
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show(
            (New-Object Windows.UI.Notifications.ToastNotification $xml))
    } catch { Write-WLog "Toast failed: $($_.Exception.Message)" }
}

function Show-UpdatePrompt([string]$NewVersion, [string]$CurrentVersion) {
    if (-not (Test-Path -LiteralPath $script:PromptScript)) { Write-WLog 'update-prompt.ps1 missing'; return }
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$script:PromptScript`"", '-NewVersion', $NewVersion, '-CurrentVersion', $CurrentVersion)
}

function Show-UpdateProgress([string]$Version) {
    if (-not (Test-Path -LiteralPath $script:ProgressScript)) {
        Write-WLog 'update-progress.ps1 missing'
        & $script:Deps.Toast ((Heb 'עדכון Claude מתחיל')) ((Heb 'Claude ייסגר לכמה דקות, יתעדכן לגרסה ') + $Version + (Heb ' ויחזור עם RTL.'))
        return
    }
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$script:ProgressScript`"", '-Version', $Version)
}

# Add-AppxPackage in its own runspace so its progress records (percent of the
# download and install) can be read while it runs. Throws like the cmdlet does.
function Add-PackageWithProgress([string]$Url, $OnProgress) {
    $ps = [powershell]::Create()
    try {
        [void]$ps.AddCommand('Add-AppxPackage').AddParameter('Path', $Url).AddParameter('ForceApplicationShutdown').AddParameter('ErrorAction', 'Stop')
        $h = $ps.BeginInvoke()
        $last = -1
        while (-not $h.IsCompleted) {
            Start-Sleep -Milliseconds 700
            $n = $ps.Streams.Progress.Count
            if ($n -gt 0 -and $OnProgress) {
                $pct = [int]$ps.Streams.Progress[$n - 1].PercentComplete
                if ($pct -ge 0 -and $pct -ne $last) { $last = $pct; & $OnProgress $pct }
            }
        }
        [void]$ps.EndInvoke($h)
        if ($ps.Streams.Error.Count -gt 0) { throw $ps.Streams.Error[0].Exception }
    } finally { $ps.Dispose() }
}

# Seconds per stage: the defaults, replaced by what earlier updates measured.
function Get-StageEstimates($State) {
    $est = [ordered]@{}
    foreach ($k in $script:DefaultStageSecs.Keys) {
        $v = $script:DefaultStageSecs[$k]
        $saved = $null
        if ($State.stageSecs -is [hashtable]) { $saved = $State.stageSecs[$k] }
        elseif ($State.stageSecs -and $State.stageSecs.PSObject.Properties[$k]) { $saved = $State.stageSecs.$k }
        if ($saved -as [double]) { $v = [Math]::Max(3, [Math]::Min(1800, [double]$saved)) }
        $est[$k] = [int]$v
    }
    return $est
}

# Halfway between the old estimate and what this update took, per measured stage.
function Update-StageEstimates($Est, $Measured) {
    $out = @{}
    foreach ($k in $Est.Keys) {
        $v = [double]$Est[$k]
        if ($Measured.ContainsKey($k)) { $v = ($v + [double]$Measured[$k]) / 2 }
        $out[$k] = [int][Math]::Round([Math]::Max(3, [Math]::Min(1800, $v)))
    }
    return $out
}

# Rewrites update-progress.json for the progress window and times each stage.
function Write-UpdateProgress($Prog, [string]$Stage, $StagePercent = $null, [string]$Status = 'running', [string]$Message = '') {
    $now = Get-Date
    if ($Stage -and $Stage -ne $Prog.stage) {
        if ($Prog.stage) { $Prog.measured[$Prog.stage] = ($now - $Prog.stageStartedAt).TotalSeconds }
        $Prog.stage = $Stage; $Prog.stageStartedAt = $now
    }
    if ($Status -ne 'running' -and -not $Prog.measured.ContainsKey($Prog.stage)) {
        $Prog.measured[$Prog.stage] = ($now - $Prog.stageStartedAt).TotalSeconds
    }
    $names = @($Prog.est.Keys)
    $doc = [ordered]@{
        version = $Prog.version; pid = $PID; status = $Status; message = $Message
        stages = @(foreach ($k in $names) { [ordered]@{ name = $k; est = $Prog.est[$k] } })
        stageIndex = [array]::IndexOf($names, $Prog.stage); stageStart = $Prog.stageStartedAt.ToString('o')
        stagePercent = $StagePercent
    }
    # Write then rename, so the window never reads half a file.
    try {
        $tmp = "$script:ProgressFile.tmp"
        $doc | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $script:ProgressFile -Force
    } catch {}
}

# ---------------------------------------------------------------------------
# The update itself
# ---------------------------------------------------------------------------
function Invoke-ClaudeUpdate($State, [string]$Why) {
    $label = "$($State.pendingVersion)"
    $launcherLock = New-Object Threading.Mutex($false, 'Local\ClaudeLauncherRepair')
    $locked = $false
    try {
        try { $locked = $launcherLock.WaitOne([TimeSpan]::FromMinutes(12)) } catch [Threading.AbandonedMutexException] { $locked = $true }
        Write-WLog "Updating Claude to $label ($Why)."
        $prog = @{ version = $label; est = (Get-StageEstimates $State); stage = $null; stageStartedAt = $null; measured = @{} }
        Write-UpdateProgress $prog 'close'
        & $script:Deps.ShowProgress $label
        $profiles = Get-OpenProfiles (& $script:Deps.ClaudeMainProcs)
        & $script:Deps.StopClaude
        Write-UpdateProgress $prog 'install'
        $onProgress = { param($pct) Write-UpdateProgress $prog 'install' $pct }
        $installed = $false
        for ($try = 1; $try -le 2 -and -not $installed; $try++) {
            try { & $script:Deps.AddPackage $State.pendingUrl $onProgress; $installed = $true }
            catch {
                Write-WLog "Add-AppxPackage attempt $try failed: $($_.Exception.Message)"
                & $script:Deps.StopClaude
                & $script:Deps.Sleep 5
            }
        }
        if (-not $installed) {
            $State.lastResult = 'install-failed'
            Write-UpdateProgress $prog 'open'
            & $script:Deps.StartProfiles $profiles
            Write-UpdateProgress $prog 'open' $null 'failed' ((Heb 'Windows לא התקין את העדכון. Claude נפתח בגרסה הקיימת.'))
            & $script:Deps.Toast ((Heb 'עדכון Claude נכשל')) ((Heb 'Windows לא התקין את העדכון. Claude נפתח בגרסה הקיימת. פרטים ב-watcher.log.'))
            return $false
        }
        Write-UpdateProgress $prog 'rtl'
        $repair = & $script:Deps.RunRepair
        Write-WLog "Repair task: $($repair.Result) $($repair.Message)"
        Write-UpdateProgress $prog 'open'
        & $script:Deps.StartProfiles $profiles
        if ($repair.Result -in @('ok', 'already')) {
            Write-UpdateProgress $prog 'open' $null 'done' ((Heb 'Claude עודכן לגרסה ') + $label + (Heb ' ונפתח עם RTL.'))
            $State.stageSecs = Update-StageEstimates $prog.est $prog.measured
            & $script:Deps.Toast ((Heb 'Claude עודכן')) ((Heb 'גרסה ') + $label + (Heb ' מותקנת, וה-RTL הוחל מחדש.'))
            $State.lastResult = 'ok'
        } else {
            Write-UpdateProgress $prog 'open' $null 'failed' ((Heb 'Claude עודכן, אבל ה-RTL לא הוחל. אפשר להריץ את קיצור הדרך Update Claude RTL.'))
            & $script:Deps.Toast ((Heb 'Claude עודכן, ה-RTL לא הוחל')) ((Heb 'תוצאת התיקון: ') + $repair.Result + (Heb '. אפשר להריץ את קיצור הדרך Update Claude RTL.'))
            $State.lastResult = "repair-$($repair.Result)"
        }
        $State.pendingVersion = $null; $State.pendingUrl = $null; $State.mode = $null
        $State.at = $null; $State.promptedAt = $null; $State.busyNotified = $false
        return $true
    } finally {
        if ($locked) { $launcherLock.ReleaseMutex() }
        $launcherLock.Dispose()
    }
}

# One pass of the update manager. Returns the (possibly changed) state.
function Invoke-ManagerTick($State, [switch]$ForceCheck) {
    $now = & $script:Deps.Now
    $State = Merge-PromptChoice $State

    # 1. Hourly look at the release feed.
    $last = ConvertTo-Date $State.lastCheck
    if ($ForceCheck -or -not $last -or ($now - $last).TotalMinutes -ge $script:CheckEveryMin) {
        $State.lastCheck = $now.ToString('o')
        try {
            $rel = ConvertFrom-Feed (& $script:Deps.GetFeed)
            $installed = & $script:Deps.GetInstalledVer
            if (-not $rel) { Write-WLog 'Release feed answer not recognized - ignored.' }
            elseif ($installed -and $rel.Version -gt $installed) {
                if ("$($State.pendingVersion)" -ne $rel.Label) {
                    Write-WLog "Claude $($rel.Label) is available (installed $installed)."
                    $State.pendingVersion = $rel.Label; $State.pendingUrl = $rel.Url
                    $State.mode = 'ask'; $State.promptedAt = $null; $State.busyNotified = $false
                } else { $State.pendingUrl = $rel.Url }
            } elseif ($State.pendingVersion -and $installed -and (ConvertTo-Version $State.pendingVersion) -le $installed) {
                Write-WLog "Claude $installed is installed - clearing the pending update."
                $State.pendingVersion = $null; $State.pendingUrl = $null; $State.mode = $null
            }
        } catch { Write-WLog "Feed check failed: $($_.Exception.Message)" }
    }

    # 2. Claude froze on an update Windows is holding: same path as "when idle".
    if (& $script:Deps.StuckSignal) {
        if (-not $State.pendingVersion) {
            try {
                $rel = ConvertFrom-Feed (& $script:Deps.GetFeed)
                if ($rel) { $State.pendingVersion = $rel.Label; $State.pendingUrl = $rel.Url }
            } catch {}
        }
        if ($State.pendingVersion -and $State.mode -ne 'idle') {
            Write-WLog 'Claude is frozen on a waiting update - will finish it as soon as no session is working.'
            $State.mode = 'idle'
        }
    }

    if (-not $State.pendingVersion) { return $State }

    switch ("$($State.mode)") {
        'snooze' {
            $until = ConvertTo-Date $State.snoozeUntil
            if (-not $until -or $now -ge $until) { $State.mode = 'ask'; $State.promptedAt = $null }
        }
        'at' {
            $at = ConvertTo-Date $State.at
            if (-not $at -or $now -ge $at) { $State.mode = 'idle'; Write-WLog 'Scheduled time reached.' }
        }
    }

    switch ("$($State.mode)") {
        'ask' {
            $prompted = ConvertTo-Date $State.promptedAt
            if (-not $prompted -or ($now - $prompted).TotalHours -ge $script:RepromptAfterHours) {
                $cur = "$(& $script:Deps.GetInstalledVer)"
                & $script:Deps.ShowPrompt $State.pendingVersion $cur
                $State.promptedAt = $now.ToString('o')
            }
        }
        { $_ -in @('now', 'idle') } {
            $act = Get-SessionActivity
            if ($act.Idle) {
                [void](Invoke-ClaudeUpdate $State $act.Reason)
            } else {
                Write-WLog "Update waits: $($act.Reason)."
                if ($State.mode -eq 'now' -or -not $State.busyNotified) {
                    & $script:Deps.Toast ((Heb 'העדכון ממתין לסיום הסשנים')) ((Heb 'יש סשן של Claude Code שעובד עכשיו. העדכון יתבצע אוטומטית כשכל הסשנים יסתיימו.'))
                    $State.busyNotified = $true
                }
                $State.mode = 'idle'
            }
        }
    }
    return $State
}

# ---------------------------------------------------------------------------
# RTL re-patch when a new Claude version starts (no download, no elevation here).
# ---------------------------------------------------------------------------
function Get-PatchedVersion {
    try { return [version](Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json).patchedVersion } catch { return $null }
}

$script:LastRepairStart = [datetime]::MinValue
function Test-AndRepair([string]$ExePath) {
    if ($ExePath -notmatch '\\WindowsApps\\Claude_(\d+(?:\.\d+){1,3})_') { return }
    $ver = [version]$Matches[1]
    $patched = Get-PatchedVersion
    if ($patched -and $ver -le $patched) { return }
    if (((Get-Date) - $script:LastRepairStart).TotalSeconds -lt 90) { return }
    $script:LastRepairStart = Get-Date
    Write-WLog "Claude $ver started unpatched (patched: $patched) - starting the repair task."
    $r = & $script:Deps.RunRepair
    Write-WLog "Repair task: $($r.Result) $($r.Message)"
}

function Invoke-WatcherLoop {
    Write-WLog "Watcher started (PID $PID, user $env:USERNAME)."
    try { Get-ClaudeMainProcesses | Select-Object -First 1 | ForEach-Object { Test-AndRepair $_.ExecutablePath } } catch {}
    $query = "SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_Process' AND TargetInstance.Name = 'claude.exe'"
    Register-CimIndicationEvent -Query $query -SourceIdentifier 'ClaudeProcessCreated' | Out-Null
    $state = Read-ManagerState
    $state = Invoke-ManagerTick $state
    Save-ManagerState $state
    while ($true) {
        $ev = Wait-Event -SourceIdentifier 'ClaudeProcessCreated' -Timeout 300
        if ($ev) {
            try { Test-AndRepair $ev.SourceEventArgs.NewEvent.TargetInstance.ExecutablePath }
            catch { Write-WLog "Event handler error: $($_.Exception.Message)" }
            finally { Remove-Event -EventIdentifier $ev.EventIdentifier }
            continue
        }
        try {
            $state = Read-ManagerState      # the prompt window writes the user's choice here
            $state = Invoke-ManagerTick $state
            Save-ManagerState $state
        } catch { Write-WLog "Manager tick error: $($_.Exception.Message)" }
    }
}

# Dot-sourcing (tests) loads the functions only.
if ($MyInvocation.InvocationName -ne '.') { Invoke-WatcherLoop }
