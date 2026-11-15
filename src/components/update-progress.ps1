# Claude RTL Patch -- update progress window (update-progress.ps1).
#
# Started by watcher.ps1 (signed-in user, no admin rights) when a Claude update
# begins. Reads update-progress.json, which the watcher rewrites at every stage and
# during the install, and shows the stage, a progress bar and when Claude should be
# open again. Closing the window does not stop the update. The window closes by itself
# when the update ends or when the watcher process is gone.
#
# Hebrew text appears only inside (Heb '...') calls (turned into \u escapes by the build).

param([ValidatePattern('^(\d+(\.\d+){1,3})?$')][string]$Version = '')

function Heb([string]$s) { return [regex]::Unescape($s) }

$script:ProgressFile = Join-Path $env:LOCALAPPDATA 'ClaudeRtlPatch\update-progress.json'

function Get-StageTitle([string]$Name) {
    switch ($Name) {
        'close'   { return (Heb 'סוגר את חלונות Claude') }
        'install' { return (Heb 'מוריד ומתקין את הגרסה החדשה') }
        'rtl'     { return (Heb 'מחיל מחדש את ה-RTL') }
        'open'    { return (Heb 'פותח את Claude') }
    }
    return $Name
}

function ConvertTo-LocalTime($Value) {
    if (-not $Value) { return $null }
    try {
        $d = [datetime]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        if ($d.Kind -eq 'Utc') { return $d.ToLocalTime() }
        return $d
    } catch { return $null }
}

# Overall percent and seconds left, from the stage estimates and the time (or the real
# install progress, when Windows reports it) spent in the current stage.
function Get-ProgressView($P, [datetime]$Now) {
    $stages = @($P.stages)
    $idx = [Math]::Max(0, [Math]::Min($stages.Count - 1, [int]$P.stageIndex))
    $total = 0.0; foreach ($s in $stages) { $total += [double]$s.est }
    if ($total -le 0) { $total = 1 }
    $before = 0.0; for ($i = 0; $i -lt $idx; $i++) { $before += [double]$stages[$i].est }
    $after = 0.0;  for ($i = $idx + 1; $i -lt $stages.Count; $i++) { $after += [double]$stages[$i].est }
    $cur = [Math]::Max(1.0, [double]$stages[$idx].est)
    $start = ConvertTo-LocalTime $P.stageStart
    $elapsed = if ($start) { [Math]::Max(0.0, ($Now - $start).TotalSeconds) } else { 0.0 }
    $real = $null
    if ($null -ne $P.stagePercent -and "$($P.stagePercent)" -ne '') { $real = [double]$P.stagePercent }
    if ($real -ne $null -and $real -ge 5) {
        $frac = [Math]::Min(1.0, $real / 100)
        $curLeft = if ($frac -lt 1) { $elapsed * (1 - $frac) / $frac } else { 0 }
    } else {
        $frac = [Math]::Min(0.95, $elapsed / $cur)
        $curLeft = [Math]::Max(5.0, $cur - $elapsed)
    }
    $view = @{
        Percent = [int][Math]::Round(100 * ($before + $cur * $frac) / $total)
        SecondsLeft = [int][Math]::Ceiling($curLeft + $after)
        Step = $idx + 1; Steps = $stages.Count; Title = (Get-StageTitle "$($stages[$idx].name)")
    }
    if ("$($P.status)" -ne 'running') { $view.Percent = 100; $view.SecondsLeft = 0 }
    return $view
}

function Format-TimeLeft([int]$Seconds) {
    if ($Seconds -le 10) { return (Heb 'Claude ייפתח בעוד כמה שניות') }
    if ($Seconds -lt 60) { return (Heb 'Claude ייפתח בעוד פחות מדקה') }
    $min = [int][Math]::Ceiling($Seconds / 60)
    if ($min -eq 1) { return (Heb 'Claude ייפתח בעוד כדקה') }
    return (Heb 'Claude ייפתח בעוד כ-') + $min + (Heb ' דקות')
}

function Read-Progress {
    try { return Get-Content -LiteralPath $script:ProgressFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Show-Window {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = (Heb 'עדכון Claude')
    $form.RightToLeft = 'Yes'
    $form.RightToLeftLayout = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false; $form.MinimizeBox = $true
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $form.ClientSize = New-Object System.Drawing.Size(440, 178)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = (Heb 'מעדכן את Claude') + $(if ($Version) { (Heb ' לגרסה ') + $Version } else { '' })
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $title.SetBounds(16, 12, 408, 26)
    $form.Controls.Add($title)

    $stage = New-Object System.Windows.Forms.Label
    $stage.SetBounds(16, 44, 408, 22)
    $form.Controls.Add($stage)

    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Style = 'Continuous'; $bar.Minimum = 0; $bar.Maximum = 100
    $bar.RightToLeftLayout = $true      # fills from the right, like the text reads
    $bar.SetBounds(16, 72, 408, 22)
    $form.Controls.Add($bar)

    $eta = New-Object System.Windows.Forms.Label
    $eta.SetBounds(16, 102, 408, 40)
    $form.Controls.Add($eta)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = (Heb 'אפשר לסגור את החלון. העדכון ימשיך ברקע.')
    $hint.ForeColor = [System.Drawing.Color]::Gray
    $hint.SetBounds(16, 148, 408, 20)
    $form.Controls.Add($hint)

    $script:UiForm = $form; $script:UiStage = $stage; $script:UiBar = $bar; $script:UiEta = $eta; $script:UiHint = $hint
    $script:UiEndAt = $null; $script:UiLastRead = Get-Date

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500
    $timer.Add_Tick({
        $now = Get-Date
        if ($script:UiEndAt) { if ($now -ge $script:UiEndAt) { $script:UiForm.Close() }; return }
        $p = Read-Progress
        if (-not $p) {
            # A read can fail now and then; give up only after a minute without one.
            if (($now - $script:UiLastRead).TotalSeconds -gt 60) { $script:UiForm.Close() }
            return
        }
        $script:UiLastRead = $now
        $v = Get-ProgressView $p $now
        $script:UiBar.Value = [Math]::Max(0, [Math]::Min(100, $v.Percent))
        if ("$($p.status)" -eq 'running') {
            $script:UiStage.Text = (Heb 'שלב ') + $v.Step + (Heb ' מתוך ') + $v.Steps + ': ' + $v.Title
            $script:UiEta.Text = Format-TimeLeft $v.SecondsLeft
            if ($p.pid -and -not (Get-Process -Id ([int]$p.pid) -ErrorAction SilentlyContinue)) { $script:UiForm.Close() }
        } else {
            $failed = "$($p.status)" -eq 'failed'
            $script:UiHint.Visible = $false
            $script:UiStage.Text = if ($failed) { (Heb 'העדכון לא הושלם') } else { (Heb 'הסתיים') }
            $script:UiEta.Text = if ($p.message) { "$($p.message)" } elseif ($failed) { '' } else { (Heb 'Claude עודכן ונפתח.') }
            $script:UiEndAt = $now.AddSeconds($(if ($failed) { 15 } else { 5 }))
        }
    })
    $form.Add_Shown({ $timer.Start() })
    [void]$form.ShowDialog()
    $timer.Dispose()
}

# Dot-sourcing (tests) loads the functions only.
if ($MyInvocation.InvocationName -ne '.') {
    $mutex = New-Object Threading.Mutex($false, 'Local\ClaudeRtlUpdateProgress')
    $owned = $false
    try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { exit 0 }     # a progress window is already on screen
    try { Show-Window } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
