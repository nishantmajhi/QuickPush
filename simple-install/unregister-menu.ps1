# Removes whichever Quick Push install is present - the registry-only one this
# folder installs, the DLL one install.bat installs, or a half-finished mix of
# the two. Nothing here is required to exist; each step reports what it found.

$ErrorActionPreference = "SilentlyContinue"

$installDir = Join-Path $env:LOCALAPPDATA "QuickPush"

# A shell extension that is deleted but still registered leaves explorer.exe
# with a CLSID pointing at nothing, which it retries on every folder it opens.
# Unregistering has to happen before the file goes.
$dll = Join-Path $installDir "quickpush.dll"
if ($env:LOCALAPPDATA -and (Test-Path -LiteralPath $dll)) {
    Write-Host "Unregistering shell extension..."
    & regsvr32.exe /u /s $dll
}

$keys = @(
    # Current cascading-menu entries
    "HKCU:\Software\Classes\Directory\Background\shell\QuickPush",
    "HKCU:\Software\Classes\Directory\shell\QuickPush",
    # Legacy (pre-submenu) entries, in case an older version was installed
    "HKCU:\Software\Classes\Directory\Background\shell\GitQuickPush",
    "HKCU:\Software\Classes\Directory\Background\shell\GitQuickStatus",
    "HKCU:\Software\Classes\Directory\shell\GitQuickPush",
    "HKCU:\Software\Classes\Directory\shell\GitQuickStatus",
    # The DLL handler's own registration, if install.bat was used and the DLL
    # has since been deleted by hand (regsvr32 /u above cannot run then)
    "HKCU:\Software\Classes\Directory\Background\shellex\ContextMenuHandlers\QuickPush",
    "HKCU:\Software\Classes\Directory\shellex\ContextMenuHandlers\QuickPush",
    "HKCU:\Software\Classes\CLSID\{9b29e102-0e3f-4fa0-a659-42e76281100f}"
)

$removed = 0
foreach ($key in $keys) {
    if (Test-Path -LiteralPath $key) {
        Remove-Item -LiteralPath $key -Recurse -Force
        $removed++
    }
}

# Guarded: with LOCALAPPDATA unset, Join-Path would have produced "\QuickPush",
# which is a folder at the root of the current drive, not this tool's.
if (-not $env:LOCALAPPDATA) {
    Write-Host "LOCALAPPDATA is not set, so the installed files were left alone."
} elseif (Test-Path -LiteralPath $installDir) {
    Remove-Item -LiteralPath $installDir -Recurse -Force
    Write-Host "Removed installed files from: $installDir"
} else {
    Write-Host "No installed files found at: $installDir"
}

Write-Host "Removed $removed registry entr$(if ($removed -eq 1) { 'y' } else { 'ies' })."
Write-Host "Restart Explorer (or sign out and back in) for the menu to disappear."
