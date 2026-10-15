# Quick Push

A Windows Explorer context menu that commits and pushes a Git repository, or
creates one on GitHub, without opening a terminal.

Right-click inside a folder and the **Quick Push** submenu shows what applies
to it:

| The folder | The submenu offers |
| --- | --- |
| is a Git repository | **Commit && Push**, **Git Status** |
| is not one yet | **Init Public Repo**, **Init Private Repo** |

It is built for the case where the terminal is not worth opening: a notes
folder, a scratch project, a repository whose entire history is "update, push,
carry on".

## What each item does

**Commit && Push** stages everything in the folder, shows you the list with a
commit message box already filled in, and on OK commits and pushes. If the
branch has no upstream it sets one. If there is nothing new to commit but the
branch is ahead of the remote, it pushes that instead of telling you there is
nothing to do.

**Git Status** opens a read-only window with the branch, the remotes, the full
`git status`, and a side-by-side view of what changed since the last commit.

**Init Public/Private Repo** runs `git init`, commits everything, and uses the
GitHub CLI (`gh`) to create the repository and push to it. It needs `gh` on
PATH and a `gh auth login` done once.

## Two things it will stop and ask about

Both exist because one click is a short distance from a public repository.

**A staged file whose name looks like a secret.** `.env`, `id_rsa`, `*.pem`,
`*.pfx`, `credentials`, `*.sqlite` and a few dozen more — the full list is
`$script:QuickPushSensitivePattern` in `scripts/lib/quickpush-core.ps1`. Quick
Push stages everything, so a file like this is picked up unless `.gitignore`
already covers it. The dialog names the file and says why, and Cancel is the
default button. It matches on names, not contents: it is a prompt to look, not
a scanner.

**Nothing else.** Cancel anywhere else — the commit message box, the close box,
Escape — leaves the repository exactly as it found it, including a staging area
you had built by hand before running this by mistake.

## Installing

```
install.bat
```

Run it from the repository root. It compiles the shell extension if it finds a
compiler, falls back to a registry-only install if it does not, copies
everything to `%LOCALAPPDATA%\QuickPush`, and restarts Explorer. No admin
rights: everything goes in the current user's AppData and `HKCU`.

### The two installation paths, and which one you want

**The shell extension (`shell-extension/`) is the one to prefer.** It is a COM
`IContextMenu` handler — a DLL that Explorer loads — and it is the only way to
get a menu whose contents depend on the folder. That is the whole feature: a
repository gets Commit and Status, a plain folder gets the two Init items. It
needs a C compiler.

**The registry-only install (`simple-install/`) is the fallback.** Registry
verbs are static, so it can only offer one fixed pair of items — Commit && Push
and Git Status — whether or not the folder is a repository. It needs nothing
but PowerShell.

`install.bat` chooses for you. To force the fallback, run
`simple-install\register-menu.ps1` directly.

### Building the DLL by hand

The compiled `quickpush.dll` is not in this repository and should not be. A
shell extension loads into `explorer.exe`, which is about the most trusted
place a binary runs on a Windows desktop; a prebuilt one in a repository is
something you cannot check against the source. Build it, or publish it as a
release asset with the commit it was built from.

`resource.rc` names the icon with no path, so the icon has to sit beside it
during compilation. `install.bat` copies it there and deletes the copy
afterwards; by hand:

```sh
cd shell-extension
cp ../quickpush.ico .

# MinGW-w64
windres resource.rc -O coff -o resource_res.o
gcc -Wall -O2 -shared -o quickpush.dll \
    quickpush_shellext.c quickpush_cmdline.c resource_res.o \
    -lshell32 -lole32 -luuid -lgdi32 -lshlwapi -lcomctl32 \
    -Wl,--kill-at -Wl,--enable-stdcall-fixup

# MSVC
rc resource.rc
cl /LD /O2 quickpush_shellext.c quickpush_cmdline.c resource.res \
   /link shell32.lib ole32.lib gdi32.lib shlwapi.lib comctl32.lib \
   /OUT:quickpush.dll

regsvr32 quickpush.dll
rm quickpush.ico resource_res.o
```

### One thing to know about how it launches

Both installs run the scripts with `powershell.exe -ExecutionPolicy Bypass`.
That is necessary — a default Windows install refuses to run an unsigned local
script otherwise — and it is what every tool in this category does. The
consequence is worth stating plainly: whatever is at
`%LOCALAPPDATA%\QuickPush\*.ps1` runs when you click the menu item, so anything
able to write to that folder gets a one-click execution path out of Explorer.
On a single-user machine that folder is already yours alone and the trade is a
fair one; it is not a defect, but it is not nothing either.

## Uninstalling

```
simple-install\unregister-menu.ps1
```

It removes whichever install is present — registry entries, the DLL
registration, and `%LOCALAPPDATA%\QuickPush`. Restart Explorer afterwards.

## Layout

```
install.bat                         one-shot installer; compiles if it can
quickpush.ico                       the single canonical copy of the icon
scripts/
  commit-push.ps1                   dialogs for Commit && Push
  git-status.ps1                    dialogs for Git Status
  init-repo.ps1                     dialogs for Init Repo
  lib/
    quickpush-core.ps1              git, status parsing, the name check
    quickpush-commit.ps1            the Commit && Push sequence
shell-extension/
  quickpush_shellext.c              the COM handler
  quickpush_cmdline.[ch]            which script a click runs, and its command line
  resource.rc, resource.h           the menu icon
simple-install/
  register-menu.ps1                 registry-only install
  unregister-menu.ps1               removes either install
tests/
  run.ps1                           the whole suite
  cmdline_test.c                    the C half, built and run by run.ps1
```

The split inside `scripts/` is the thing worth knowing. The three top-level
scripts are WinForms and nothing else: theme colours, auto-sizing dialogs, a
dark title bar. Everything that *decides* anything is in `lib/`, which has no
reference to a window. `commit-push.ps1` hands its dialogs to
`Invoke-CommitPush` as three script blocks; the tests hand it three script
blocks that answer from a table. Both drive the same git.

## Tests

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1
```

152 checks, no test framework, nothing to install. The integration half builds
real throwaway repositories under `%TEMP%`, complete with a bare remote to push
to, and drives the real code with the dialogs stubbed out. `run.ps1` also
compiles and runs `tests/cmdline_test.c` when a `gcc` is on PATH, and skips it
with a note when there is not.

## Editing it

`install.bat` and `register-menu.ps1` copy the scripts to
`%LOCALAPPDATA%\QuickPush`, and that copy is what the menu runs. Editing a file
here does nothing until you re-run the installer. This is the most likely
explanation for a change that appears to have no effect.

The scripts dot-source `lib\` relative to their own folder, so `lib\` has to be
installed alongside them — both installers do that, and `tests\run.ps1` checks
that they still do.

## Requirements

- Windows 10 or 11
- Git on PATH
- PowerShell 5.1 (the one that ships with Windows)
- GitHub CLI (`gh`), for the two Init items only
- A C compiler, for the shell extension only

## Licence

Free for personal, non-commercial use. You may use, study and modify this
software for yourself, but you may not use it commercially, and you may not
share or publish it, in its original form or modified. See [LICENSE](LICENSE)
for the full terms.
