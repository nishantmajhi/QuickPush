# Code Review — QuickPush

First reviewed 2026-09-04. **Remediated 2026-09-17** on branch
`cleanup/2026-09-17`. This file is now a record of that pass rather than a
to-do list: what was fixed, what was deliberately left alone, and what the next
session should know.

## What this project is

A Windows Explorer context-menu integration that stages, commits and pushes a
Git repository in one click, or creates one on GitHub. It ships two
installation paths: a native C shell extension DLL, and a registry-only
approach that wires the menu directly to the same PowerShell scripts.

## Verdict, unchanged

The PowerShell UI work is better than it needs to be — dark-mode detection, a
themed title bar via `DwmSetWindowAttribute`, colour-coded `git status` output,
auto-sizing dialogs that cannot push their own buttons off-screen, and an input
dialog that distinguishes Cancel from OK (unlike VB's `InputBox`, as the
comment correctly notes). That is careful work and none of it was touched.

The problem was the Git behaviour, and it is fixed.

## What was wrong, and what was done

### 1. Cancelling the dialog destroyed the staging area — fixed

The order was: confirm it is a repo, `git add -A`, read the status, *then* show
the dialog. Pressing Cancel exited with everything still staged, so a partial
staging built by hand was gone with no undo.

Reproduced first, against the original code, in a scratch repository with
`a.txt` staged and `b.txt` and `secret.env` not:

```
Staged before Quick Push: a.txt
Staged after  Cancel     : a.txt, b.txt, secret.env
```

Fixed the way `VS Code Extensions/smart-commit/src/git.ts` does it:
`Get-IndexSnapshot` runs `git write-tree` before anything is staged, and every
path that does not end in a commit runs `git read-tree` on that snapshot. This
restores the index *exactly*, including the staged content of a file that was
modified again afterwards — a path-by-path `git reset HEAD -- <file>` cannot,
because it resets to HEAD rather than to what was staged. `write-tree` refuses
during a merge, so there is a fallback that unstages only what `git add -A`
added; both paths are covered by tests.

### 2. One click published anything in the folder — mitigated

`git add -A` picks up whatever `.gitignore` does not cover. There is now a
name-based check: a staged file matching `.env`, `id_rsa`, `*.pem`, `*.pfx`,
`credentials`, `*.sqlite` and thirty-odd others gets one explicit dialog naming
the file and why, with Cancel as the default button. Declining restores the
index and commits nothing.

The same check runs in `init-repo.ps1`, which was the worse case: `git add -A`
over a folder that has never had a `.gitignore`, followed by the creation of a
GitHub repository that may be public. Declining there leaves an empty local
`.git` and says so; nothing is committed and no repository is created.

It matches on names, not contents. It is a prompt to look, not a scanner, and a
false positive costs one click. `.pub` files are excluded — a public key beside
a private one is the half meant to be shared.

The commit dialog's caption now carries the file count: "Files to be committed
(7):".

### 3. The compiled DLL was committed — fixed

`shell-extension/quickpush.dll` was the only tracked binary in any C project
here. It is untracked now, with a `.gitignore` covering it and the other build
outputs, and the README explains how to build it and why a prebuilt shell
extension in a repository is a bad idea. The binary is still in history at
commit `1ace3fe` if it is ever wanted.

### 4. Non-ASCII folder paths were mangled — fixed

`CreateProcessA` with an ANSI command line meant a folder containing
Devanagari, accented Latin or CJK characters reached the script as question
marks and it opened the wrong folder, or none.

The whole extension is UTF-16 now: `SHGetPathFromIDListW`, `DragQueryFileW`,
`GetFileAttributesW`, `MENUITEMINFOW`/`InsertMenuItemW`, `CreateProcessW`, and
`GetModuleFileNameW`/`RegSetValueExW` in the registration path, which had the
same problem for an account name outside the system codepage — a mangled
`InprocServer32` path COM could never load.

Two things turned up on the way:

- `DragQueryFileA(hDrop, 0, buf, sizeof(buf))` was correct for ANSI, where
  bytes and characters are the same. The W version counts WCHARs, so a
  mechanical `A`→`W` swap would have told it the buffer was twice its real
  size. It now passes `sizeof(buf) / sizeof(wchar_t)`.
- `CM_GetCommandString` answered only `GCS_HELPTEXTA`. Explorer asks for the
  wide form on every version that matters, so the status-bar hint was blank. It
  answers both now.

### 5. Launch failures were silent — fixed

`CreateProcessA`'s return value was checked and the error returned as an
HRESULT, which Explorer ignores. A missing PowerShell, a policy block or a
half-finished install made the menu item do nothing at all, indistinguishable
from a script that ran and exited quietly. It shows a `MessageBoxW` with the
Windows error code and the command line it tried.

### 6. A branch with no upstream dumped git's advice text — fixed

`git push` on a branch with no upstream fails with a wall of `--set-upstream`
advice, which the original showed verbatim. `Get-PushArgument` now supplies
`--set-upstream <remote> <branch>` directly, which is what the user wanted
anyway — they clicked a button called "Commit & Push".

The three cases where there is genuinely nowhere to push are now explained in
words instead: no remote configured (with the `git remote add` line), several
remotes and none called `origin` (Quick Push will not guess which fork), and
detached HEAD. An unborn branch — `git init` with nothing committed — is also
handled; `rev-list` against it fails rather than returning zero, so it is asked
about separately.

### 7. `Set-Location` had no error handling — fixed

A deleted or inaccessible folder threw before the repo check and the user saw a
raw PowerShell error, not a themed dialog. `git-status.ps1` and
`init-repo.ps1` now guard it. `commit-push.ps1` no longer calls it at all: the
extracted logic uses `git -C`, so it never depends on or changes the caller's
working directory.

### 8. Command-line injection through the folder path

The first review noted this is not reachable, since Windows forbids `"` in file
names, but that the code relied on it implicitly. `QuickPushBuildCommandLine`
now refuses a path containing a quote, and refuses rather than truncates a line
that will not fit — a half-written `-Path` argument points somewhere else.
Both refusals are tested.

### 9. A bug the first review missed: the diff parser dropped changed lines

`Get-ParsedDiff` in `git-status.ps1` recognised `---` and `+++` file headers
*anywhere*, not just in the per-file header block. Inside a hunk, a removed line
whose own text begins with `--` arrives as `---...` and was silently swallowed.
Confirmed against the original parser with a four-line fixture, which produced
no old lines and no new lines at all; the fixed parser keeps all four. The
parser now only recognises headers before the first `@@` of a file, and lives in
`lib/` where it can be tested.

### 10. `unregister-menu.ps1` left a dangling shell extension — fixed

It deleted `%LOCALAPPDATA%\QuickPush` without running `regsvr32 /u` first, so a
DLL install left Explorer with a CLSID pointing at nothing, retried on every
folder opened. It now unregisters first, removes the handler's own registry
keys as well as the registry-verb ones, reports what it found, and no longer
risks deleting `\QuickPush` at the root of the current drive when
`LOCALAPPDATA` is unset.

### 11. Structure

`scripts/lib/` is new and is the point of the pass. The three top-level scripts
are WinForms and nothing else; everything that decides anything is in `lib/`,
which has no reference to a window. `commit-push.ps1` hands its dialogs to
`Invoke-CommitPush` as three script blocks, and `tests/run.ps1` hands it three
that answer from a table. `shell-extension/quickpush_cmdline.[ch]` does the same
job on the C side: which script a click runs and what its command line is,
with no COM and no Explorer, so `tests/cmdline_test.c` can link it directly.

A `LICENSE` was added (MIT, matching the rest of the archive).

## Tests

`powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1` — 152
checks, no framework, nothing to install. The integration half builds real
repositories under `%TEMP%` with a bare remote to push to. The C half is
compiled and run by the same command when a `gcc` is found, and skipped with a
note when it is not.

Every regression test was confirmed to fail against the original code first.
The two that matter are the Cancel-restores-the-index test and the diff-parser
one, both of which have their before/after output quoted above.

## Deliberately not done

- **The three scripts each carry their own copy of the dialog toolkit.**
  `Show-ThemedMessage`, `Show-ThemedInput`, the colour table and
  `Enable-DarkTitleBar` are duplicated three ways, and `Show-ThemedConfirm` is
  now duplicated twice. Unifying them means rewriting UI code that this pass
  was told to leave alone, and the duplication is at least consistent. It is
  the obvious next structural job if that constraint is ever lifted.
- **`register-menu.ps1` copies `init-repo.ps1` but wires no Init menu item.**
  Registry verbs are static, so the fallback install cannot offer a menu that
  changes with the folder; adding two unconditional Init entries would put
  "Init Public Repo" on folders that are already repositories. Left as is, and
  the README now says plainly which install is preferred and why the other
  exists.
- **The DLL has not been loaded into a live Explorer.** It compiles clean with
  `-Wall` under TDM-GCC 10.3 and exports all four COM entry points, which is
  more than was true before this pass — nothing here can register a shell
  extension and restart Explorer to see it work. See below.
- **`init-repo.ps1` was not extracted into `lib/`.** Its decisions are
  interleaved with `gh` calls that nothing here can exercise, so extracting it
  would produce untested code that merely looks tested. Only the
  credential-name check moved.

## Notes for a future session

**The install-dir trap.** `install.bat` and `register-menu.ps1` copy the
scripts to `%LOCALAPPDATA%\QuickPush`, and that copy is what the menu runs.
Editing a file in the repository does nothing until the installer is re-run.
This is the most likely explanation for "my change did nothing".

**`lib/` has to be installed too.** Both installers copy it and `tests/run.ps1`
asserts that they still do, because a missing dot-source kills the script in a
window that closes before it can be read.

**One PowerShell 5.1 trap cost an hour and is worth knowing.**
`New-Object System.Collections.Generic.List[object]` produces a list that `@()`
cannot enumerate — it throws `Argument types do not match`, while
`List[string]` and `::new()` are fine. Everything here uses
`System.Collections.ArrayList`. Related: a function returning `,@($list)` hands
back the array intact when its result is *assigned*, but `@(Get-Thing)` wraps it
again into a one-element array, and a bare `PSCustomObject` has no `.Count` at
all. That last one is how the credential-name warning silently failed to fire
the first time it was tested; there is now a unit test for exactly that shape.

**Manual check still outstanding, about twenty minutes.** Build and register
the DLL on a machine you do not mind restarting Explorer on:

1. `install.bat` from the repository root; it should report the MinGW path.
2. Right-click inside a Git repository — the submenu should read
   **Commit && Push** / **Git Status**; inside a plain folder, the two Init
   items.
3. Hover an item: the status bar should now show the help text, which was blank
   before.
4. Create a folder whose name is not ASCII (`D:\कोड\項目`), make it a
   repository, and use Commit && Push from inside it. The dialog should show
   that path correctly. This is the fix in issue 4 and is the one thing here
   that cannot be tested without Explorer.
5. Rename `%LOCALAPPDATA%\QuickPush\commit-push.ps1` and click the menu item —
   a message box should appear naming the Windows error, where the original did
   nothing at all.
6. `simple-install\unregister-menu.ps1` and confirm the menu is gone after an
   Explorer restart.

## Licence, 2026-10-02

The author chose one licence for all of their projects: free for personal,
non-commercial use, modifiable for the user's own use, and not to be
distributed, original or modified. No standard licence says that, so `LICENSE`
is a short custom text, the same in every project apart from the year and what
it excludes. The README's licence section says the same. Anything above that
calls the licence an open question, or calls the project MIT, is superseded.

## CI, 2026-10-02

`.github/workflows/ci.yml` runs `tests\run.ps1` under Windows PowerShell 5.1
on `windows-latest`. Nothing has been pushed, so it has not run on GitHub yet.
Every job was run before committing, from a fresh clone of this branch, the
way a runner would run it: Windows jobs here, in PowerShell 7 or the shell the
step names, with only the tools the job sets up on `PATH`. 152 passed, 0
skipped, so the C half ran too.

The harness ran with no global git identity, as a runner has none; the suite
sets its own in the repositories it builds.
