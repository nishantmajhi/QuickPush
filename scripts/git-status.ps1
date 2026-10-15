param(
    [string]$Path
)

if (-not $Path) {
    $Path = (Get-Location).Path
}

$Path = $Path.TrimEnd('\')

# Get-ParsedDiff and the repository helpers live in lib\ so that tests\run.ps1
# can exercise them without a screen.
. (Join-Path $PSScriptRoot "lib\quickpush-core.ps1")

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Without this, PowerShell decodes git's UTF-8 output using the console's
# codepage (often OEM 437 or Windows-1252), so any em-dash, ellipsis, or
# curly quote in a diffed file turns into garbage like "ÔÇö" or "â€¦".
# Git itself already writes UTF-8; this just tells PowerShell to read it
# back the same way.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

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

# A full line in a single color, followed by a line break.
function Write-Line {
    param($Rtb, [string]$Text = "", [System.Drawing.Color]$Color = $script:ColorFg, [bool]$Bold = $false)
    Write-Segment -Rtb $Rtb -Text $Text -Color $Color -Bold $Bold
    Write-Segment -Rtb $Rtb -Text "`n" -Color $Color
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

#
# ---- Short side-by-side diff of everything changed since the last commit ----
#
# Design goals for the block below:
#   - One row per changed line, old (left) and new (right) side by side.
#   - Each changed region ("hunk") is capped at $MaxLinesPerHunk lines per
#     side, with a "(+N more)" note instead of dumping the whole hunk -
#     this is meant to be skimmed, not a replacement for `git diff`.
#   - Every changed file is shown (no file-count cap), just each file's
#     own diff is kept short.
#   - Column width is computed from the screen's working area so the
#     table fits without ever needing a horizontal scrollbar; only
#     vertical scrolling is used for files/hunks that don't fit.
#

# Measures the pixel width of one character in a (monospace) font by
# averaging over a run of characters, so column math below lines up
# with what actually gets painted instead of guessing a fixed px/char.
function Get-MonospaceCharWidth {
    param([System.Drawing.Font]$Font)
    $sample = "0123456789ABCDEFGHIJ"
    $size = [System.Windows.Forms.TextRenderer]::MeasureText($sample, $Font)
    return [Math]::Max(1.0, $size.Width / $sample.Length)
}

# Truncates text that's too long for its column (with an ellipsis) or
# pads it out so both columns line up, no matter what came before it.
function Format-DiffCell {
    param([string]$Text, [int]$Width)
    if ($null -eq $Text) { $Text = "" }
    if ($Text.Length -gt $Width) {
        if ($Width -le 3) { return $Text.Substring(0, $Width) }
        return $Text.Substring(0, $Width - 3) + "..."
    }
    return $Text.PadRight($Width)
}

# One row of the side-by-side table, written directly into a RichTextBox:
# line number + text on the left (old, in the "removed" color) and line
# number + text on the right (new, in the "added" color). Either side
# can be blank (pure addition = blank left, pure deletion = blank right).
# Pass -IsHeader for the "OLD | NEW" column caption row instead.
function Write-DiffRow {
    param($Rtb, $LeftNum, [string]$LeftText, $RightNum, [string]$RightText, [int]$ColWidth, [int]$NumWidth, [switch]$IsHeader)
    $leftNumStr  = if ($LeftNum)  { "$LeftNum".PadLeft($NumWidth) } else { "".PadLeft($NumWidth) }
    $rightNumStr = if ($RightNum) { "$RightNum".PadLeft($NumWidth) } else { "".PadLeft($NumWidth) }
    $leftCell  = Format-DiffCell -Text $LeftText  -Width $ColWidth
    $rightCell = Format-DiffCell -Text $RightText -Width $ColWidth

    if ($IsHeader) {
        Write-Segment -Rtb $Rtb -Text "$leftNumStr $leftCell | $rightNumStr $rightCell" -Color $script:ColorDim -Bold $true
    } else {
        Write-Segment -Rtb $Rtb -Text "$leftNumStr "  -Color $script:ColorDim
        Write-Segment -Rtb $Rtb -Text $leftCell       -Color $script:ColorAccentError
        Write-Segment -Rtb $Rtb -Text " | "            -Color $script:ColorDim
        Write-Segment -Rtb $Rtb -Text "$rightNumStr "  -Color $script:ColorDim
        Write-Segment -Rtb $Rtb -Text $rightCell       -Color $script:ColorAccentInfo
    }
    Write-Segment -Rtb $Rtb -Text "`n" -Color $script:ColorFg
}


# Builds the "Changes Since Last Commit" section directly into a
# RichTextBox: a summary line, then one short side-by-side block per
# changed file (tag color-coded by status, old/new lines color-coded),
# then a color-coded list of untracked files (no previous version to
# diff against, so no diff table for those).
function Write-ChangesSection {
    param($Rtb, [int]$ColWidth, [int]$NumWidth, [int]$MaxLinesPerHunk = 3)

    Write-Line -Rtb $Rtb -Text "========================================" -Color $script:ColorAccentInfo -Bold $true
    Write-Line -Rtb $Rtb -Text "Changes Since Last Commit"                 -Color $script:ColorAccentInfo -Bold $true
    Write-Line -Rtb $Rtb -Text "========================================" -Color $script:ColorAccentInfo -Bold $true
    Write-Line -Rtb $Rtb

    git rev-parse --verify HEAD *> $null
    $hasCommits = ($LASTEXITCODE -eq 0)

    $changedFiles = @()
    if ($hasCommits) {
        $rawDiff = git diff --no-color --no-renames -U0 HEAD -- . 2>&1
        $changedFiles = Get-ParsedDiff -RawDiff ($rawDiff -join "`n")
    }

    $untracked = @(git ls-files --others --exclude-standard -- . 2>&1 | Where-Object { $_ })

    if (-not $hasCommits) {
        Write-Line -Rtb $Rtb -Text "No commits yet in this repo, so there's nothing to diff against." -Color $script:ColorFg
    } elseif ($changedFiles.Count -eq 0) {
        Write-Line -Rtb $Rtb -Text "Nothing changed since the last commit." -Color $script:ColorFg
    } else {
        $names = ($changedFiles | ForEach-Object { $_.Path }) -join ", "
        Write-Line -Rtb $Rtb -Text "$($changedFiles.Count) file(s) changed: $names" -Color $script:ColorFg -Bold $true
        Write-Line -Rtb $Rtb

        $ruler = "-" * (($ColWidth * 2) + ($NumWidth * 2) + 5)

        foreach ($file in $changedFiles) {
            $tagInfo = switch ($file.Status) {
                "Added"   { @{ Text = "[A]"; Color = $script:ColorAccentInfo } }
                "Deleted" { @{ Text = "[D]"; Color = $script:ColorAccentError } }
                default   { @{ Text = "[M]"; Color = $script:ColorModifiedTag } }
            }
            Write-Line -Rtb $Rtb -Text $ruler -Color $script:ColorDim
            Write-Segment -Rtb $Rtb -Text "$($tagInfo.Text) " -Color $tagInfo.Color -Bold $true
            Write-Segment -Rtb $Rtb -Text $file.Path -Color $script:ColorFg -Bold $true
            Write-Segment -Rtb $Rtb -Text "`n" -Color $script:ColorFg
            Write-Line -Rtb $Rtb -Text $ruler -Color $script:ColorDim

            if ($file.Binary) {
                Write-Line -Rtb $Rtb -Text "  (binary file - no text diff shown)" -Color $script:ColorDim
                Write-Line -Rtb $Rtb
                continue
            }
            if ($file.Hunks.Count -eq 0) {
                Write-Line -Rtb $Rtb -Text "  (no line changes - mode or metadata only)" -Color $script:ColorDim
                Write-Line -Rtb $Rtb
                continue
            }

            Write-DiffRow -Rtb $Rtb -LeftNum "" -LeftText "OLD" -RightNum "" -RightText "NEW" -ColWidth $ColWidth -NumWidth $NumWidth -IsHeader

            foreach ($hunk in $file.Hunks) {
                $oldTake = @($hunk.OldLines | Select-Object -First $MaxLinesPerHunk)
                $newTake = @($hunk.NewLines | Select-Object -First $MaxLinesPerHunk)
                $rowCount = [Math]::Max($oldTake.Count, $newTake.Count)

                for ($i = 0; $i -lt $rowCount; $i++) {
                    $leftNum  = if ($i -lt $oldTake.Count -and $hunk.OldCount -gt 0) { $hunk.OldStart + $i } else { $null }
                    $leftTxt  = if ($i -lt $oldTake.Count) { $oldTake[$i] } else { "" }
                    $rightNum = if ($i -lt $newTake.Count -and $hunk.NewCount -gt 0) { $hunk.NewStart + $i } else { $null }
                    $rightTxt = if ($i -lt $newTake.Count) { $newTake[$i] } else { "" }
                    Write-DiffRow -Rtb $Rtb -LeftNum $leftNum -LeftText $leftTxt -RightNum $rightNum -RightText $rightTxt -ColWidth $ColWidth -NumWidth $NumWidth
                }

                $moreOld = [Math]::Max(0, $hunk.OldLines.Count - $MaxLinesPerHunk)
                $moreNew = [Math]::Max(0, $hunk.NewLines.Count - $MaxLinesPerHunk)
                if ($moreOld -gt 0 -or $moreNew -gt 0) {
                    Write-Line -Rtb $Rtb -Text "  ... (+$moreOld more removed / +$moreNew more added in this block)" -Color $script:ColorDim
                }
            }
            Write-Line -Rtb $Rtb
        }
    }

    if ($untracked.Count -gt 0) {
        Write-Line -Rtb $Rtb -Text "Untracked files (new, not yet committed - no previous version to diff):" -Color $script:ColorFg -Bold $true
        $untracked | ForEach-Object { Write-Line -Rtb $Rtb -Text "  + $_" -Color $script:ColorUntracked }
        Write-Line -Rtb $Rtb
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

if (-not (Test-GitRepository -RepoPath $Path)) {
    Show-ThemedMessage -Text "This folder is not a Git repository:`n$Path" -Title "Quick Push" -Kind Error
    exit 1
}

$branch  = git rev-parse --abbrev-ref HEAD 2>&1
$remotes = git remote -v 2>&1
$status  = git status 2>&1

$font = New-Object System.Drawing.Font("Consolas", 10)
$script:BoldFont = New-Object System.Drawing.Font($font, [System.Drawing.FontStyle]::Bold)
$workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

# --------------------------------------------------------------
# Work out how wide the diff table's two columns can be so the
# whole row fits on screen with room to spare - this is what lets
# the window rely on vertical scrolling only, never horizontal.
# --------------------------------------------------------------
$charWidth   = Get-MonospaceCharWidth -Font $font
$numWidth    = 5                                  # line-number column width
$chromePx    = 70                                 # form borders/margins
$scrollbarPx = 25                                 # vertical scrollbar reserve
$maxFormWidthPx = [int]($workArea.Width * 0.92)

$availableTextPx = $maxFormWidthPx - $chromePx - $scrollbarPx
$availableChars  = [Math]::Max(40, [int]([Math]::Floor($availableTextPx / $charWidth)))
$fixedChars      = ($numWidth * 2) + 5            # two number columns + " " + " | " + " " (5 literal chars, see Write-DiffRow)
$colWidth        = [Math]::Max(18, [Math]::Min(70, [int]([Math]::Floor(($availableChars - $fixedChars) / 2))))

$rowChars   = $fixedChars + ($colWidth * 2)
$neededTextPx = [int]($rowChars * $charWidth)
$formWidth  = [Math]::Min($maxFormWidthPx, [Math]::Max(700, $neededTextPx + $chromePx + $scrollbarPx))

$form = New-Object System.Windows.Forms.Form
$form.Text = "Git Status - $(Split-Path $Path -Leaf)"
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(500, 300)
$form.BackColor = $script:ColorBg
$form.ForeColor = $script:ColorFg

# Width is sized to fit the diff table with no horizontal scrolling;
# height is capped and relies on the textbox's vertical scrollbar for
# anything (file list, diff, status) that doesn't fit on one screen.
$form.Size = New-Object System.Drawing.Size(
    $formWidth,
    ([Math]::Min(750, [int]($workArea.Height * 0.85)))
)

$textBox = New-Object System.Windows.Forms.RichTextBox
$textBox.ReadOnly = $true
$textBox.ScrollBars = "Vertical"
$textBox.WordWrap = $false
$textBox.Dock = "Fill"
$textBox.BorderStyle = "None"
$textBox.Font = $font
$textBox.BackColor = $script:ColorBg
$textBox.ForeColor = $script:ColorFg
$textBox.DetectUrls = $false

Write-Line -Rtb $textBox -Text "Folder:  $Path" -Color $script:ColorFg
Write-Line -Rtb $textBox -Text "Branch:  $branch" -Color $script:ColorFg
Write-Line -Rtb $textBox
Write-Line -Rtb $textBox -Text "Remotes:" -Color $script:ColorFg
if ($remotes) {
    $remotes -split "`n" | ForEach-Object { Write-Line -Rtb $textBox -Text "  $_" -Color $script:ColorFg }
} else {
    Write-Line -Rtb $textBox -Text "  (none configured)" -Color $script:ColorDim
}
Write-Line -Rtb $textBox

Write-Line -Rtb $textBox -Text "========================================" -Color $script:ColorFg -Bold $true
Write-Line -Rtb $textBox -Text "Full 'git status' output"                 -Color $script:ColorFg -Bold $true
Write-Line -Rtb $textBox -Text "========================================" -Color $script:ColorFg -Bold $true
Write-Line -Rtb $textBox
$status -split "`n" | ForEach-Object { Write-Line -Rtb $textBox -Text $_ -Color $script:ColorFg }
Write-Line -Rtb $textBox

Write-ChangesSection -Rtb $textBox -ColWidth $colWidth -NumWidth $numWidth

$textBox.SelectionStart = 0
$textBox.SelectionLength = 0

$form.Controls.Add($textBox)
$form.Add_Shown({ Enable-DarkTitleBar -Form $form; $form.Activate(); $textBox.Focus() })
[void]$form.ShowDialog()
