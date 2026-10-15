param(
    [string]$Path
)

if (-not $Path) {
    $Path = (Get-Location).Path
}

# Trim trailing backslash that Explorer sometimes passes
$Path = $Path.TrimEnd('\')

# Everything that decides anything lives in lib\. This file is the dialogs.
. (Join-Path $PSScriptRoot "lib\quickpush-core.ps1")
. (Join-Path $PSScriptRoot "lib\quickpush-commit.ps1")

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Test-DarkMode {
    try {
        $val = Get-ItemPropertyValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "AppsUseLightTheme" -ErrorAction Stop
        return ($val -eq 0)
    } catch {
        return $false
    }
}

$script:IsDark = Test-DarkMode
if ($script:IsDark) {
    $script:ColorBg          = [System.Drawing.Color]::FromArgb(32,32,32)
    $script:ColorFg          = [System.Drawing.Color]::FromArgb(240,240,240)
    $script:ColorPanel       = [System.Drawing.Color]::FromArgb(45,45,48)
    $script:ColorBtnBg       = [System.Drawing.Color]::FromArgb(63,63,70)
    $script:ColorBtnFg       = [System.Drawing.Color]::White
    $script:ColorBorder      = [System.Drawing.Color]::FromArgb(80,80,80)
    $script:ColorAccentInfo  = [System.Drawing.Color]::FromArgb(90,200,120)
    $script:ColorAccentError = [System.Drawing.Color]::FromArgb(230,90,90)
    $script:ColorDim         = [System.Drawing.Color]::FromArgb(140,140,140)
    $script:ColorModifiedTag = [System.Drawing.Color]::FromArgb(230,180,80)
    $script:ColorUntracked   = [System.Drawing.Color]::FromArgb(120,175,235)
} else {
    $script:ColorBg          = [System.Drawing.Color]::White
    $script:ColorFg          = [System.Drawing.Color]::FromArgb(20,20,20)
    $script:ColorPanel       = [System.Drawing.Color]::FromArgb(245,245,245)
    $script:ColorBtnBg       = [System.Drawing.Color]::FromArgb(225,225,225)
    $script:ColorBtnFg       = [System.Drawing.Color]::Black
    $script:ColorBorder      = [System.Drawing.Color]::FromArgb(200,200,200)
    $script:ColorAccentInfo  = [System.Drawing.Color]::FromArgb(40,140,70)
    $script:ColorAccentError = [System.Drawing.Color]::FromArgb(190,40,40)
    $script:ColorDim         = [System.Drawing.Color]::FromArgb(120,120,120)
    $script:ColorModifiedTag = [System.Drawing.Color]::FromArgb(150,105,10)
    $script:ColorUntracked   = [System.Drawing.Color]::FromArgb(20,85,165)
}

# Paints the title bar dark too (Windows 10 2004+ / 11). Silently no-ops on
# older builds where DWMWA_USE_IMMERSIVE_DARK_MODE isn't supported.
function Enable-DarkTitleBar {
    param($Form)
    if (-not $script:IsDark) { return }
    try {
        if (-not ([System.Management.Automation.PSTypeName]'QuickPushNative.Dwm').Type) {
            Add-Type -Name Dwm -Namespace QuickPushNative -MemberDefinition '
                [DllImport("dwmapi.dll")]
                public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
            '
        }
        $val = 1
        [QuickPushNative.Dwm]::DwmSetWindowAttribute($Form.Handle, 20, [ref]$val, 4) | Out-Null
    } catch {}
}

# Appends one colored run of text to a RichTextBox. RichTextBox has no
# concept of "current color" - you set SelectionColor/SelectionFont,
# then whatever gets typed/appended next picks it up, which is why
# every append has to move SelectionStart to the end first.
function Write-Segment {
    param($Rtb, [string]$Text, [System.Drawing.Color]$Color = $script:ColorFg, [bool]$Bold = $false)
    $Rtb.SelectionStart = $Rtb.TextLength
    $Rtb.SelectionLength = 0
    $Rtb.SelectionColor = $Color
    $Rtb.SelectionFont = if ($Bold) { $script:BoldFont } else { $Rtb.Font }
    $Rtb.AppendText($Text)
}

# Maps a `git status --short` two-letter code (index/worktree columns)
# to a color: red for deletions, green for additions, amber for
# modifications, blue for untracked, default otherwise. Deletion takes
# priority since a partly-deleted file is the thing most worth noticing.
function Get-StatusLineColor {
    param([string]$X, [string]$Y)
    if ($X -eq '?' -and $Y -eq '?') { return $script:ColorUntracked }
    if ($X -eq 'D' -or $Y -eq 'D')  { return $script:ColorAccentError }
    if ($X -eq 'A')                 { return $script:ColorAccentInfo }
    if ($X -eq 'M' -or $Y -eq 'M')  { return $script:ColorModifiedTag }
    if ($X -eq 'R' -or $X -eq 'C')  { return $script:ColorModifiedTag }
    return $script:ColorFg
}

# Same auto-height behavior as New-AutoTextArea, but color-codes each
# line of a `git status --short`-style file list (added/modified/
# deleted/untracked) instead of rendering it as flat text. Lines that
# don't look like a status line (e.g. a plain caption) fall back to
# the default text color.
function New-ColoredFileListArea {
    param([string]$Text, [int]$Width, [int]$MaxHeight, [System.Drawing.Font]$Font)

    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.ReadOnly = $true
    $rtb.BorderStyle = "None"
    $rtb.TabStop = $false
    $rtb.Font = $Font
    $rtb.Width = $Width
    $rtb.BackColor = $script:ColorBg
    $rtb.ForeColor = $script:ColorFg
    $rtb.DetectUrls = $false

    $textLines = $Text -split "`n"
    for ($i = 0; $i -lt $textLines.Count; $i++) {
        if ($i -gt 0) { Write-Segment -Rtb $rtb -Text "`n" -Color $script:ColorFg }
        $line = $textLines[$i]
        $color = $script:ColorFg
        if ($line -match '^(.)(.)\s(.*)$') {
            $color = Get-StatusLineColor -X $Matches[1] -Y $Matches[2]
        }
        Write-Segment -Rtb $rtb -Text $line -Color $color
    }
    $rtb.SelectionStart = 0
    $rtb.SelectionLength = 0

    $lineCount = [Math]::Max(1, $textLines.Count)
    $lineHeight = [System.Windows.Forms.TextRenderer]::MeasureText("Ay", $Font).Height
    $desired = ($lineCount * $lineHeight) + 12

    if ($desired -gt $MaxHeight) {
        $rtb.Height = $MaxHeight
        $rtb.ScrollBars = "Vertical"
    } else {
        $rtb.Height = $desired
        $rtb.ScrollBars = "None"
    }
    return $rtb
}

# Creates a read-only, auto-height multiline textbox: grows to fit the text
# up to $MaxHeight, then clips with a vertical scrollbar instead of letting
# content spill past the edge of the window.
function New-AutoTextArea {
    param([string]$Text, [int]$Width, [int]$MaxHeight, [System.Drawing.Font]$Font)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true
    $tb.ReadOnly = $true
    $tb.BorderStyle = "None"
    $tb.TabStop = $false
    $tb.Font = $Font
    $tb.Text = $Text
    $tb.Width = $Width
    $tb.BackColor = $script:ColorBg
    $tb.ForeColor = $script:ColorFg

    $lineCount = [Math]::Max(1, ($Text -split "`n").Count)
    $lineHeight = [System.Windows.Forms.TextRenderer]::MeasureText("Ay", $Font).Height
    $desired = ($lineCount * $lineHeight) + 12

    if ($desired -gt $MaxHeight) {
        $tb.Height = $MaxHeight
        $tb.ScrollBars = "Vertical"
    } else {
        $tb.Height = $desired
        $tb.ScrollBars = "None"
    }
    return $tb
}

function Show-ThemedMessage {
    param([string]$Text, [string]$Title, [ValidateSet("Info","Error")][string]$Kind = "Info")

    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $maxFormHeight = [int]($workArea.Height * 0.8)
    $contentWidth = 420

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = $script:ColorBg
    $form.ForeColor = $script:ColorFg
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $form.Width = 460

    $accent = if ($Kind -eq "Error") { $script:ColorAccentError } else { $script:ColorAccentInfo }

    $bar = New-Object System.Windows.Forms.Panel
    $bar.BackColor = $accent
    $bar.Dock = "Top"
    $bar.Height = 4
    $form.Controls.Add($bar)

    $maxTextAreaHeight = $maxFormHeight - 110  # leave room for bar, padding, button
    $textArea = New-AutoTextArea -Text $Text -Width $contentWidth -MaxHeight ([Math]::Max(60, $maxTextAreaHeight)) -Font $form.Font
    $textArea.Location = New-Object System.Drawing.Point(20, 20)
    $form.Controls.Add($textArea)

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = "OK"
    $okBtn.BackColor = $script:ColorBtnBg
    $okBtn.ForeColor = $script:ColorBtnFg
    $okBtn.FlatStyle = "Flat"
    $okBtn.FlatAppearance.BorderColor = $script:ColorBorder
    $okBtn.Size = New-Object System.Drawing.Size(90, 30)
    $okBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okBtn.Location = New-Object System.Drawing.Point(($contentWidth + 20 - $okBtn.Width), ($textArea.Bottom + 16))
    $form.Controls.Add($okBtn)

    $form.AcceptButton = $okBtn
    $form.CancelButton = $okBtn
    $form.ClientSize = New-Object System.Drawing.Size(($contentWidth + 40), ($okBtn.Bottom + 20))

    $form.Add_Shown({ Enable-DarkTitleBar -Form $form; $form.Activate() })
    [void]$form.ShowDialog()
}

# Show-ThemedMessage with a second button, for the one question this tool has
# to ask before it does something it cannot take back. Cancel is the default -
# closing the window or pressing Escape does not publish anything - because
# the whole point is to interrupt somebody who is about to press Enter.
function Show-ThemedConfirm {
    param([string]$Text, [string]$Title, [string]$ProceedLabel = "Commit anyway")

    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $maxFormHeight = [int]($workArea.Height * 0.8)
    $contentWidth = 420

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = $script:ColorBg
    $form.ForeColor = $script:ColorFg
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $form.Width = 460

    $bar = New-Object System.Windows.Forms.Panel
    $bar.BackColor = $script:ColorAccentError
    $bar.Dock = "Top"
    $bar.Height = 4
    $form.Controls.Add($bar)

    $maxTextAreaHeight = $maxFormHeight - 110
    $textArea = New-AutoTextArea -Text $Text -Width $contentWidth -MaxHeight ([Math]::Max(60, $maxTextAreaHeight)) -Font $form.Font
    $textArea.Location = New-Object System.Drawing.Point(20, 20)
    $form.Controls.Add($textArea)

    $proceedBtn = New-Object System.Windows.Forms.Button
    $proceedBtn.Text = $ProceedLabel
    $proceedBtn.BackColor = $script:ColorBtnBg
    $proceedBtn.ForeColor = $script:ColorBtnFg
    $proceedBtn.FlatStyle = "Flat"
    $proceedBtn.FlatAppearance.BorderColor = $script:ColorBorder
    $proceedBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $proceedBtn.Size = New-Object System.Drawing.Size(130, 30)
    $proceedBtn.Location = New-Object System.Drawing.Point(($contentWidth + 20 - 130 - 95), ($textArea.Bottom + 16))
    $form.Controls.Add($proceedBtn)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.BackColor = $script:ColorBtnBg
    $cancelBtn.ForeColor = $script:ColorBtnFg
    $cancelBtn.FlatStyle = "Flat"
    $cancelBtn.FlatAppearance.BorderColor = $script:ColorBorder
    $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelBtn.Size = New-Object System.Drawing.Size(90, 30)
    $cancelBtn.Location = New-Object System.Drawing.Point(($contentWidth + 20 - 90), ($textArea.Bottom + 16))
    $form.Controls.Add($cancelBtn)

    $form.AcceptButton = $cancelBtn
    $form.CancelButton = $cancelBtn
    $form.ClientSize = New-Object System.Drawing.Size(($contentWidth + 40), ($cancelBtn.Bottom + 20))

    $form.Add_Shown({ Enable-DarkTitleBar -Form $form; $form.Activate(); $cancelBtn.Focus() })
    return ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK)
}

# Returns the entered string on OK, or $null on Cancel/close - unlike VB's
# InputBox, which returns the box's text either way and can't tell Cancel
# from OK, this makes Cancel actually mean cancel.
#
# -InfoText is optional read-only reference text shown above the input
# (e.g. a file list) in a scrollable area that's capped in height so it
# can never push the OK/Cancel buttons off-screen.
function Show-ThemedInput {
    param(
        [string]$Prompt,
        [string]$Title,
        [string]$DefaultValue = "",
        [string]$InfoText = "",
        [switch]$ColorizeInfoText
    )

    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $maxFormHeight = [int]($workArea.Height * 0.8)
    $contentWidth = 420

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = $script:ColorBg
    $form.ForeColor = $script:ColorFg
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $form.Width = 460

    $bar = New-Object System.Windows.Forms.Panel
    $bar.BackColor = $script:ColorAccentInfo
    $bar.Dock = "Top"
    $bar.Height = 4
    $form.Controls.Add($bar)

    $y = 20

    if ($InfoText) {
        $maxInfoHeight = [int](($maxFormHeight - 180) * 0.7)
        if ($ColorizeInfoText) {
            $infoArea = New-ColoredFileListArea -Text $InfoText -Width $contentWidth -MaxHeight ([Math]::Max(50, $maxInfoHeight)) -Font $form.Font
        } else {
            $infoArea = New-AutoTextArea -Text $InfoText -Width $contentWidth -MaxHeight ([Math]::Max(50, $maxInfoHeight)) -Font $form.Font
        }
        $infoArea.Location = New-Object System.Drawing.Point(20, $y)
        $form.Controls.Add($infoArea)
        $y = $infoArea.Bottom + 14
    }

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Prompt
    $label.ForeColor = $script:ColorFg
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(20, $y)
    $form.Controls.Add($label)
    $y = $label.Bottom + 6

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Text = $DefaultValue
    $textBox.BackColor = $script:ColorPanel
    $textBox.ForeColor = $script:ColorFg
    $textBox.BorderStyle = "FixedSingle"
    $textBox.Location = New-Object System.Drawing.Point(20, $y)
    $textBox.Size = New-Object System.Drawing.Size($contentWidth, 24)
    $form.Controls.Add($textBox)
    $y = $textBox.Bottom + 16

    $okBtn = New-Object System.Windows.Forms.Button
    $okBtn.Text = "OK"
    $okBtn.BackColor = $script:ColorBtnBg
    $okBtn.ForeColor = $script:ColorBtnFg
    $okBtn.FlatStyle = "Flat"
    $okBtn.FlatAppearance.BorderColor = $script:ColorBorder
    $okBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okBtn.Size = New-Object System.Drawing.Size(85, 28)
    $okBtn.Location = New-Object System.Drawing.Point(($contentWidth + 20 - 85 - 90), $y)
    $form.Controls.Add($okBtn)

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = "Cancel"
    $cancelBtn.BackColor = $script:ColorBtnBg
    $cancelBtn.ForeColor = $script:ColorBtnFg
    $cancelBtn.FlatStyle = "Flat"
    $cancelBtn.FlatAppearance.BorderColor = $script:ColorBorder
    $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelBtn.Size = New-Object System.Drawing.Size(85, 28)
    $cancelBtn.Location = New-Object System.Drawing.Point(($contentWidth + 20 - 85), $y)
    $form.Controls.Add($cancelBtn)

    $form.AcceptButton = $okBtn
    $form.CancelButton = $cancelBtn
    $form.ClientSize = New-Object System.Drawing.Size(($contentWidth + 40), ($okBtn.Bottom + 20))

    $form.Add_Shown({ Enable-DarkTitleBar -Form $form; $textBox.Focus(); $textBox.SelectAll() })
    $result = $form.ShowDialog()

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $textBox.Text
    } else {
        return $null
    }
}


# ---------------------------------------------------------------------------
# Wiring: the dialogs above, handed to the logic in lib\.
# ---------------------------------------------------------------------------

$askMessage = {
    param($summary, $fileCount, $defaultMessage)
    Show-ThemedInput -InfoText "Files to be committed ($fileCount):`n$summary" `
                     -Prompt "Commit message:" -Title "Quick Push" `
                     -DefaultValue $defaultMessage -ColorizeInfoText
}

$confirmRisk = {
    param($hits)
    $plural = if ($hits.Count -eq 1) { "file" } else { "files" }
    Show-ThemedConfirm -Title "Quick Push - check before committing" -Text (
        "$($hits.Count) staged $plural " + $(if ($hits.Count -eq 1) { "looks" } else { "look" }) +
        " like something you did not mean to publish:`n`n" +
        (Format-SensitiveWarning -Hits $hits) +
        "`n`nQuick Push stages everything in the folder, so a file like this is picked up " +
        "unless .gitignore already covers it. Committing it puts it in the repository's history, " +
        "where deleting it later does not remove it."
    )
}

$notify = {
    param($text, $kind)
    Show-ThemedMessage -Text $text -Title "Quick Push" -Kind $kind
}

exit (Invoke-CommitPush -Path $Path -AskMessage $askMessage -ConfirmRisk $confirmRisk -Notify $notify)
