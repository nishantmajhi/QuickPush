$ErrorActionPreference = "Stop"

$installDir = "$env:LOCALAPPDATA\QuickPush"
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

$repoRoot   = Join-Path $PSScriptRoot ".."
$scriptsDir = Join-Path $repoRoot "scripts"

$scriptFiles = @("commit-push.ps1", "git-status.ps1", "init-repo.ps1")
foreach ($name in $scriptFiles) {
    $src = Join-Path $scriptsDir $name
    if (-not (Test-Path $src)) {
        Write-Error "$name not found in scripts\. Make sure the repo structure is intact (scripts\ folder alongside simple-install\ and shell-extension\)."
        exit 1
    }
    Copy-Item -Path $src -Destination "$installDir\$name" -Force
}

# The scripts dot-source lib\ relative to their own folder, so it has to travel
# with them. Leaving it behind is a silent failure: the menu item launches, the
# script dies on the missing dot-source, and the window closes too fast to read.
$libSrc = Join-Path $scriptsDir "lib"
if (-not (Test-Path $libSrc)) {
    Write-Error "scripts\lib\ not found. Make sure the repo structure is intact."
    exit 1
}
$libDest = Join-Path $installDir "lib"
New-Item -ItemType Directory -Force -Path $libDest | Out-Null
Copy-Item -Path (Join-Path $libSrc "*.ps1") -Destination $libDest -Force

# The icon is the single copy at the repo root (not inside scripts\).
$iconSrc = Join-Path $repoRoot "quickpush.ico"
if (-not (Test-Path $iconSrc)) {
    Write-Error "quickpush.ico not found in the repo root. Make sure the repo structure is intact."
    exit 1
}
Copy-Item -Path $iconSrc -Destination "$installDir\quickpush.ico" -Force

$commitPushScript = "$installDir\commit-push.ps1"
$gitStatusScript  = "$installDir\git-status.ps1"
$iconPath         = "$installDir\quickpush.ico"

function Set-LabelAndIcon {
    param([string]$KeyPath, [string]$Label, [string]$Icon = $iconPath)
    New-Item -Path $KeyPath -Force | Out-Null
    Set-ItemProperty -Path $KeyPath -Name "(default)" -Value $Label
    Set-ItemProperty -Path $KeyPath -Name "Icon" -Value $Icon
}

function New-ParentMenu {
    param([string]$BasePath, [string]$Label)
    $shellKey = "$BasePath\shell\QuickPush"
    Set-LabelAndIcon -KeyPath $shellKey -Label $Label
    Set-ItemProperty -Path $shellKey -Name "SubCommands" -Value ""
}

function New-ChildItem2 {
    param([string]$BasePath, [string]$ItemKeyName, [string]$Label, [string]$ScriptPath, [string]$ArgPlaceholder)
    $itemKey = "$BasePath\shell\QuickPush\shell\$ItemKeyName"
    Set-LabelAndIcon -KeyPath $itemKey -Label $Label

    $cmdKey = "$itemKey\command"
    New-Item -Path $cmdKey -Force | Out-Null
    $cmd = "powershell.exe -NoLogo -ExecutionPolicy Bypass -File `"$ScriptPath`" `"$ArgPlaceholder`""
    Set-ItemProperty -Path $cmdKey -Name "(default)" -Value $cmd
}

# Clean up entries from older, pre-cascading versions of this script if present
Remove-Item -Path "HKCU:\Software\Classes\Directory\Background\shell\GitQuickPush"   -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "HKCU:\Software\Classes\Directory\Background\shell\GitQuickStatus" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "HKCU:\Software\Classes\Directory\shell\GitQuickPush"   -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "HKCU:\Software\Classes\Directory\shell\GitQuickStatus" -Recurse -Force -ErrorAction SilentlyContinue

# --- Right-click on empty space inside a folder (operates on current folder) ---
New-ParentMenu -BasePath "HKCU:\Software\Classes\Directory\Background" -Label "Quick Push"
New-ChildItem2 -BasePath "HKCU:\Software\Classes\Directory\Background" -ItemKeyName "CommitPush" -Label "Commit && Push" -ScriptPath $commitPushScript -ArgPlaceholder "%V"
New-ChildItem2 -BasePath "HKCU:\Software\Classes\Directory\Background" -ItemKeyName "GitStatus"  -Label "Git Status"     -ScriptPath $gitStatusScript  -ArgPlaceholder "%V"

# --- Right-click directly on a folder (operates on that folder) ---
New-ParentMenu -BasePath "HKCU:\Software\Classes\Directory" -Label "Quick Push"
New-ChildItem2 -BasePath "HKCU:\Software\Classes\Directory" -ItemKeyName "CommitPush" -Label "Commit && Push" -ScriptPath $commitPushScript -ArgPlaceholder "%1"
New-ChildItem2 -BasePath "HKCU:\Software\Classes\Directory" -ItemKeyName "GitStatus"  -Label "Git Status"     -ScriptPath $gitStatusScript  -ArgPlaceholder "%1"

Write-Host "Installed."
Write-Host "Right-click inside (or on) any Git repo folder, then open 'Quick Push' to find 'Commit & Push' and 'Git Status'."
Write-Host "Scripts installed to: $installDir"
