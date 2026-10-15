param(
    [string]$Path,
    [ValidateSet("public", "private")]
    [string]$Visibility = "public"
)

if (-not $Path) {
    $Path = (Get-Location).Path
}
$Path = $Path.TrimEnd('\')

# The credential-name check below is shared with commit-push.ps1.
. (Join-Path $PSScriptRoot "lib\quickpush-core.ps1")

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
} else {
    $script:ColorBg          = [System.Drawing.Color]::White
    $script:ColorFg          = [System.Drawing.Color]::FromArgb(20,20,20)
    $script:ColorPanel       = [System.Drawing.Color]::FromArgb(245,245,245)
    $script:ColorBtnBg       = [System.Drawing.Color]::FromArgb(225,225,225)
    $script:ColorBtnFg       = [System.Drawing.Color]::Black
    $script:ColorBorder      = [System.Drawing.Color]::FromArgb(200,200,200)
    $script:ColorAccentInfo  = [System.Drawing.Color]::FromArgb(40,140,70)
    $script:ColorAccentError = [System.Drawing.Color]::FromArgb(190,40,40)
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

# Show-ThemedMessage with a second button, for the one question this script
# has to ask before it does something irreversible. Cancel is the default -
# Escape and the close box publish nothing - because the whole point is to
# interrupt somebody who is about to press Enter.
#
# This is a copy of the same function in commit-push.ps1, as Show-ThemedMessage
# and Show-ThemedInput already are. See review.md: the three scripts each carry
# their own copy of the dialog toolkit, and unifying them would mean rewriting
# UI this pass was asked to leave alone.
function Show-ThemedConfirm {
    param([string]$Text, [string]$Title, [string]$ProceedLabel = "Publish anyway")

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
        [string]$InfoText = ""
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
        $infoArea = New-AutoTextArea -Text $InfoText -Width $contentWidth -MaxHeight ([Math]::Max(50, $maxInfoHeight)) -Font $form.Font
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

# A folder Explorer has since deleted, or lost access to, throws here. An
# unguarded Set-Location kills the script with a raw PowerShell error before
# any of the themed dialogs above can be reached.
try {
    Set-Location -LiteralPath $Path -ErrorAction Stop
} catch {
    Show-ThemedMessage -Text "This folder no longer exists, or cannot be opened:`n$Path" -Title "Quick Push" -Kind Error
    exit 1
}

git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -eq 0) {
    Show-ThemedMessage -Text "This folder is already a Git repository.`n`nUse 'Commit & Push' instead." -Title "Quick Push" -Kind Info
    exit 0
}

$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
    Show-ThemedMessage -Text "GitHub CLI ('gh') was not found.`n`nInstall it, then run 'gh auth login' once, and try again:`n`n  winget install GitHub.cli" -Title "Quick Push" -Kind Error
    exit 1
}

$authCheck = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Not logged into GitHub CLI yet. Starting 'gh auth login' - follow the prompts below..."
    Write-Host ""
    gh auth login
    if ($LASTEXITCODE -ne 0) {
        Show-ThemedMessage -Text "GitHub authentication failed or was cancelled." -Title "Quick Push" -Kind Error
        exit 1
    }
}

$defaultName = Split-Path $Path -Leaf
$repoName = Show-ThemedInput -Prompt "Repository name:" -Title "Quick Push - Init $Visibility repo" -DefaultValue $defaultName
if ($null -eq $repoName) {
    exit 0
}
if ([string]::IsNullOrWhiteSpace($repoName)) { $repoName = $defaultName }

$defaultMsg = "Initial commit"
$message = Show-ThemedInput -Prompt "Commit message:" -Title "Quick Push - Init $Visibility repo" -DefaultValue $defaultMsg
if ($null -eq $message) {
    exit 0
}
if ([string]::IsNullOrWhiteSpace($message)) { $message = $defaultMsg }

Write-Host "Initializing repository in: $Path"
git init | Out-Host
git add -A | Out-Host

# This is the riskiest path in the whole tool: `git add -A` over a folder that
# has never had a .gitignore, followed by the creation of a GitHub repository
# that may be public. Anything credential-shaped gets one explicit question
# first. Nothing has been committed or published at this point, so declining
# leaves only an empty local repository behind.
$stagedZ = git status --porcelain -z
$sensitive = Get-SensitiveStagedFile -Paths (Get-StagedPathFromPorcelainZ -PorcelainZ ($stagedZ -join ""))
if ($sensitive.Count -gt 0) {
    $plural = if ($sensitive.Count -eq 1) { "file" } else { "files" }
    $proceed = Show-ThemedConfirm -Title "Quick Push - check before publishing" -Text (
        "$($sensitive.Count) $plural about to go into a new $Visibility GitHub repository " +
        "look like something you did not mean to publish:`n`n" +
        (Format-SensitiveWarning -Hits $sensitive) +
        "`n`nThis folder has no .gitignore yet, so everything in it was staged. " +
        "Once pushed, deleting the file later does not remove it from the repository's history."
    )
    if (-not $proceed) {
        Write-Host ""
        Write-Host "Cancelled. Nothing was committed and no GitHub repository was created."
        Write-Host "A local .git folder was created and left in place; delete it if you do not want it."
        Write-Host ""
        Read-Host "Press Enter to close this window"
        exit 0
    }
}

$status = git status --porcelain
if (-not $status) {
    git commit --allow-empty -m "$message" | Out-Host
} else {
    git commit -m "$message" | Out-Host
}

Write-Host ""
Write-Host "Creating $Visibility GitHub repository '$repoName' and pushing..."
Write-Host ""
gh repo create $repoName "--$Visibility" --source=. --remote=origin --push | Out-Host
$ghExit = $LASTEXITCODE

Write-Host ""
if ($ghExit -eq 0) {
    Write-Host "Done. Repository created and pushed."
} else {
    Write-Host "Something went wrong creating or pushing the repository - see output above."
    Write-Host "(Common cause: a repo named '$repoName' already exists on your GitHub account.)"
}

Write-Host ""
Read-Host "Press Enter to close this window"
