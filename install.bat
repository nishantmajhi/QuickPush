@echo off
setlocal EnableDelayedExpansion

:: ============================================================
::  QuickPush — one-shot installer
::  Run from the repo root (the folder containing this file).
::
::  What this does, in order:
::    1. Tries to compile quickpush.dll with MinGW-w64 (windres + gcc)
::    2. If that fails, tries MSVC (rc + cl)
::    3. If no compiler is found, falls back to the simple registry
::       install (no DLL, static menu — same as simple-install\install.ps1)
::    4. Copies files to %LOCALAPPDATA%\QuickPush, registers the DLL
::       (Option 1) or writes the registry entries (Option 3), then
::       restarts Explorer.
::
::  No admin rights needed — everything goes into the current user's
::  AppData and HKCU registry hive.
:: ============================================================

set "ROOT=%~dp0"
:: Strip trailing backslash
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

set "SRC=%ROOT%\shell-extension"
set "SCRIPTS=%ROOT%\scripts"
set "ICON=%ROOT%\quickpush.ico"
set "INSTALL_DIR=%LOCALAPPDATA%\QuickPush"

echo.
echo  =========================================
echo   QuickPush Installer
echo  =========================================
echo.

:: --------------------------------------------------
:: Sanity-check that the repo layout is intact
:: --------------------------------------------------
if not exist "%SRC%\quickpush_shellext.c" (
    echo  [ERROR] shell-extension\quickpush_shellext.c not found.
    echo          Run this script from the repo root folder.
    goto :fail
)
if not exist "%SCRIPTS%\commit-push.ps1" (
    echo  [ERROR] scripts\commit-push.ps1 not found.
    echo          Make sure the scripts\ folder is present next to this file.
    goto :fail
)
if not exist "%SCRIPTS%\lib\quickpush-core.ps1" (
    echo  [ERROR] scripts\lib\quickpush-core.ps1 not found.
    echo          The scripts dot-source lib\, so it has to be there too.
    goto :fail
)
if not exist "%ICON%" (
    echo  [ERROR] quickpush.ico not found in the repo root.
    echo          Run this script from the repo root folder.
    goto :fail
)

:: --------------------------------------------------
:: Detect compiler
:: --------------------------------------------------
set "COMPILER=none"

where windres >nul 2>&1 && where gcc >nul 2>&1 && (
    set "COMPILER=mingw"
    echo  [INFO] Found MinGW-w64 ^(windres + gcc^) -- will compile DLL.
    goto :compile
)

where rc >nul 2>&1 && where cl >nul 2>&1 && (
    set "COMPILER=msvc"
    echo  [INFO] Found MSVC ^(rc + cl^) -- will compile DLL.
    goto :compile
)

echo  [WARN] No C compiler found ^(MinGW-w64 or MSVC^).
echo         Falling back to simple registry install ^(static menu, no DLL^).
echo.
goto :simple_install

:: --------------------------------------------------
:: Compile
:: --------------------------------------------------
:compile

:: resource.rc references quickpush.ico by filename with no path,
:: so the icon must sit next to the .rc file during compilation.
:: The one true copy lives at the repo root; this is a disposable
:: build-time copy, cleaned up after compilation below.
echo  [INFO] Copying icon to shell-extension\ for resource compilation...
copy /Y "%ICON%" "%SRC%\quickpush.ico" >nul

pushd "%SRC%"

if "%COMPILER%"=="mingw" (
    echo  [INFO] Compiling resources with windres...
    windres resource.rc -O coff -o resource_res.o
    if errorlevel 1 (
        echo  [ERROR] windres failed.
        popd
        goto :compile_failed
    )

    echo  [INFO] Linking DLL with gcc...
    gcc -Wall -O2 -shared -o quickpush.dll quickpush_shellext.c quickpush_cmdline.c resource_res.o ^
        -lshell32 -lole32 -luuid -lgdi32 -lshlwapi -lcomctl32 ^
        -Wl,--kill-at -Wl,--enable-stdcall-fixup
    if errorlevel 1 (
        echo  [ERROR] gcc failed.
        popd
        goto :compile_failed
    )
    del /Q resource_res.o 2>nul
)

if "%COMPILER%"=="msvc" (
    echo  [INFO] Compiling resources with rc...
    rc resource.rc
    if errorlevel 1 (
        echo  [ERROR] rc failed.
        popd
        goto :compile_failed
    )

    echo  [INFO] Linking DLL with cl...
    cl /LD /O2 quickpush_shellext.c quickpush_cmdline.c resource.res ^
       /link shell32.lib ole32.lib gdi32.lib shlwapi.lib comctl32.lib ^
       /OUT:quickpush.dll
    if errorlevel 1 (
        echo  [ERROR] cl failed.
        popd
        goto :compile_failed
    )
    del /Q resource.res quickpush_shellext.obj quickpush_cmdline.obj 2>nul
)

popd

:: Remove the disposable build-time copy so the repo keeps a single
:: canonical quickpush.ico (the one at the repo root).
del /Q "%SRC%\quickpush.ico" 2>nul

if not exist "%SRC%\quickpush.dll" (
    echo  [ERROR] Compilation appeared to succeed but quickpush.dll was not produced.
    goto :compile_failed
)

echo  [INFO] Compilation succeeded.
goto :dll_install

:compile_failed
echo.
echo  [WARN] Compilation failed. Falling back to simple registry install.
goto :simple_install

:: --------------------------------------------------
:: Option 1 — DLL install
:: --------------------------------------------------
:dll_install
echo.
echo  [INFO] Installing shell extension (DLL)...

:: Unregister any existing DLL first so we can overwrite it
if exist "%INSTALL_DIR%\quickpush.dll" (
    regsvr32 /u /s "%INSTALL_DIR%\quickpush.dll"
)

:: Also clean up any simple-install registry entries that might be present
reg delete "HKCU\Software\Classes\Directory\Background\shell\QuickPush" /f >nul 2>&1
reg delete "HKCU\Software\Classes\Directory\shell\QuickPush"            /f >nul 2>&1

mkdir "%INSTALL_DIR%" 2>nul

copy /Y "%SRC%\quickpush.dll"      "%INSTALL_DIR%\quickpush.dll"  >nul
copy /Y "%SCRIPTS%\commit-push.ps1" "%INSTALL_DIR%\commit-push.ps1" >nul
copy /Y "%SCRIPTS%\git-status.ps1"  "%INSTALL_DIR%\git-status.ps1"  >nul
copy /Y "%SCRIPTS%\init-repo.ps1"   "%INSTALL_DIR%\init-repo.ps1"   >nul
copy /Y "%ICON%"                    "%INSTALL_DIR%\quickpush.ico"   >nul

:: The scripts dot-source lib\ relative to their own folder, so it has to travel
:: with them. Leaving it behind is a silent failure: the menu item launches,
:: the script dies on the missing dot-source, and the window closes too fast
:: to read.
mkdir "%INSTALL_DIR%\lib" 2>nul
copy /Y "%SCRIPTS%\lib\*.ps1"       "%INSTALL_DIR%\lib\"            >nul

echo  [INFO] Registering DLL (user hive, no admin needed)...
regsvr32 /s "%INSTALL_DIR%\quickpush.dll"
if errorlevel 1 (
    echo  [ERROR] regsvr32 failed. The DLL may not load correctly.
    goto :fail
)

echo  [INFO] DLL registered successfully.
goto :restart_explorer

:: --------------------------------------------------
:: Option 2 — Simple PowerShell registry install
:: --------------------------------------------------
:simple_install
echo  [INFO] Running simple-install\register-menu.ps1...
powershell.exe -NoLogo -ExecutionPolicy Bypass -File "%ROOT%\simple-install\register-menu.ps1"
if errorlevel 1 (
    echo  [ERROR] install.ps1 failed.
    goto :fail
)
goto :restart_explorer

:: --------------------------------------------------
:: Restart Explorer
:: --------------------------------------------------
:restart_explorer
echo.
echo  [INFO] Restarting Explorer so the new menu entry is picked up...
taskkill /f /im explorer.exe >nul 2>&1
timeout /t 1 /nobreak >nul
start explorer.exe

echo.
echo  =========================================
echo   Installation complete.
echo   Right-click inside any folder and look
echo   for the Quick Push submenu.
echo  =========================================
echo.
goto :done

:fail
echo.
echo  Installation did not complete. See errors above.
echo.
exit /b 1

:done
endlocal
