# Claude RTL Patch -- "a Claude update is available" window (update-prompt.ps1).
#
# Started hidden by watcher.ps1 as the signed-in user (no admin rights). Shows one
# right-to-left window and writes the choice to update-choice.json in the user's
# LocalAppData; the watcher reads it on its next pass (within 5 minutes) and deletes
# it. Closing the window without choosing means "ask me again later".
#
# Hebrew text appears only inside (Heb '...') calls (turned into \u escapes by the build).

param(
    [Parameter(Mandatory)][ValidatePattern('^\d+(\.\d+){1,3}$')][string]$NewVersion,
    [ValidatePattern('^(\d+(\.\d+){1,3})?$')][string]$CurrentVersion = ''
)

function Heb([string]$s) { return [regex]::Unescape($s) }

$script:ChoiceFile = Join-Path $env:LOCALAPPDATA 'ClaudeRtlPatch\update-choice.json'

# Next occurrence of HH:00 (default for the "at a set time" picker).
function Get-NextAt([datetime]$Now, [int]$Hour) {
    $t = $Now.Date.AddHours($Hour)
    if ($t -le $Now.AddMinutes(5)) { $t = $t.AddDays(1) }
    return $t
}

function New-Choice([string]$Mode, [datetime]$Now, $At) {
    $c = [ordered]@{ version = $NewVersion; mode = $Mode; madeAt = $Now.ToString('o'); at = $null; snoozeUntil = $null }
    if ($Mode -eq 'at')     { $c.at = ([datetime]$At).ToString('o') }
    if ($Mode -eq 'snooze') { $c.snoozeUntil = $Now.Date.AddDays(1).AddHours(9).ToString('o') }
    return $c
}

function Save-Choice($Choice) {
    $dir = Split-Path $script:ChoiceFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Choice | ConvertTo-Json | Set-Content -LiteralPath $script:ChoiceFile -Encoding UTF8
}

function Show-Window {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $font = New-Object System.Drawing.Font('Segoe UI', 10)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = (Heb 'עדכון ל-Claude')
    $form.RightToLeft = 'Yes'
    $form.RightToLeftLayout = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false; $form.MinimizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.Font = $font
    $form.ClientSize = New-Object System.Drawing.Size(460, 300)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = (Heb 'גרסה חדשה של Claude זמינה: ') + $NewVersion
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $title.AutoSize = $false
    $title.SetBounds(16, 14, 428, 26)
    $form.Controls.Add($title)

    $body = New-Object System.Windows.Forms.Label
    $cur = if ($CurrentVersion) { (Heb 'מותקנת עכשיו: ') + $CurrentVersion + '. ' } else { '' }
    $body.Text = $cur + (Heb 'העדכון סוגר את כל חלונות Claude לכדקה, מתקין את הגרסה, מחיל מחדש את ה-RTL ופותח אותם שוב. לפני כל עדכון נבדק שאין סשן של Claude Code שעובד.')
    $body.AutoSize = $false
    $body.SetBounds(16, 46, 428, 66)
    $form.Controls.Add($body)

    $now = Get-Date
    $script:PromptChoice = $null
    $script:PromptForm = $form

    $mk = {
        param([string]$Text, [int]$Y, [string]$Mode)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $Text
        $b.SetBounds(16, $Y, 428, 32)
        $b.Tag = $Mode
        $b.Add_Click({
            $script:PromptChoice = New-Choice $this.Tag (Get-Date) $null
            $script:PromptForm.Close()
        })
        $form.Controls.Add($b)
        return $b
    }
    $btnNow  = & $mk ((Heb 'לעדכן עכשיו')) 120 'now'
    $btnIdle = & $mk ((Heb 'לעדכן כשכל הסשנים יסתיימו')) 158 'idle'
    $form.AcceptButton = $btnIdle
    $form.ActiveControl = $btnIdle      # Enter never means "update right now"

    $picker = New-Object System.Windows.Forms.DateTimePicker
    $picker.Format = 'Custom'
    $picker.CustomFormat = 'dd/MM/yyyy HH:mm'
    $picker.MinDate = $now
    $picker.Value = Get-NextAt $now 2
    $picker.RightToLeft = 'No'
    $picker.SetBounds(16, 200, 170, 30)
    $form.Controls.Add($picker)
    $script:PromptPicker = $picker

    $btnAt = New-Object System.Windows.Forms.Button
    $btnAt.Text = (Heb 'לתזמן לשעה הזו')
    $btnAt.SetBounds(196, 197, 248, 32)
    $btnAt.Add_Click({
        $script:PromptChoice = New-Choice 'at' (Get-Date) $script:PromptPicker.Value
        $script:PromptForm.Close()
    })
    $form.Controls.Add($btnAt)

    $btnLater = & $mk ((Heb 'להזכיר לי מחר בבוקר')) 246 'snooze'
    $form.CancelButton = $btnLater

    [void]$form.ShowDialog()
    return $script:PromptChoice
}

# Dot-sourcing (tests) loads the functions only.
if ($MyInvocation.InvocationName -ne '.') {
    $mutex = New-Object Threading.Mutex($false, 'Local\ClaudeRtlUpdatePrompt')
    $owned = $false
    try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { exit 0 }     # a prompt is already on screen
    try {
        $choice = Show-Window
        if ($choice) { Save-Choice $choice }
    } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
