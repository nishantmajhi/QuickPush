<#
    Quick Push - test suite.

        powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1

    No test framework: the project had none, and adding one to a folder of
    three PowerShell scripts is a bigger imposition than sixty lines of
    harness. Everything below runs on stock Windows PowerShell 5.1.

    The integration tests build real throwaway repositories under $env:TEMP,
    complete with a bare remote to push to, and drive the real Invoke-CommitPush
    with script blocks standing in for the dialogs. They are slower than the
    pure tests and worth every second: the bug this pass exists to fix - Cancel
    destroying a hand-built staging area - cannot be seen in a pure test.
#>

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root "scripts\lib\quickpush-core.ps1")
. (Join-Path $root "scripts\lib\quickpush-commit.ps1")

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0
$script:CurrentGroup = ""

function Group {
    param([string]$Name)
    $script:CurrentGroup = $Name
    Write-Host ""
    Write-Host "  $Name" -ForegroundColor Cyan
}

function Ok {
    param([string]$Name)
    $script:Passed++
    Write-Host "    ok   $Name" -ForegroundColor DarkGray
}

function Fail {
    param([string]$Name, [string]$Detail)
    $script:Failed++
    Write-Host "    FAIL $Name" -ForegroundColor Red
    foreach ($line in ($Detail -split "`n")) { Write-Host "         $line" -ForegroundColor Red }
}

function Skip {
    param([string]$Name, [string]$Why)
    $script:Skipped++
    Write-Host "    skip $Name ($Why)" -ForegroundColor Yellow
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    $e = if ($null -eq $Expected) { "<null>" } else { [string]$Expected }
    $a = if ($null -eq $Actual) { "<null>" } else { [string]$Actual }
    if ($e -ceq $a) { Ok $Name } else { Fail $Name "expected: $e`n  actual: $a" }
}

function Assert-True {
    param($Condition, [string]$Name, [string]$Detail = "")
    if ($Condition) { Ok $Name } else { Fail $Name ("expected true" + $(if ($Detail) { "`n$Detail" } else { "" })) }
}

function Assert-Null {
    param($Value, [string]$Name)
    if ($null -eq $Value) { Ok $Name } else { Fail $Name "expected <null>, got: $Value" }
}

function Assert-Sequence {
    param([string[]]$Expected, $Actual, [string]$Name)
    $a = @($Actual)
    $e = @($Expected)
    if (($e -join "|") -ceq ($a -join "|")) { Ok $Name }
    else { Fail $Name "expected: [$($e -join ', ')]`n  actual: [$($a -join ', ')]" }
}

# ---------------------------------------------------------------------------
# Throwaway repositories
# ---------------------------------------------------------------------------

$script:TempRoots = New-Object System.Collections.ArrayList

<#
    A repository with one commit, a bare remote called origin, and a tracked
    a.txt and b.txt. -NoRemote leaves origin off; -NoCommit leaves the branch
    unborn.
#>
function New-TestRepo {
    param([switch]$NoRemote, [switch]$NoCommit)

    $base = Join-Path $env:TEMP ("quickpush-test-" + [guid]::NewGuid().ToString("N").Substring(0, 10))
    $work = Join-Path $base "work"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    [void]$script:TempRoots.Add($base)

    & git -C $work init --quiet --initial-branch=main 2>&1 | Out-Null
    & git -C $work config user.email "tests@quickpush.invalid" 2>&1 | Out-Null
    & git -C $work config user.name "Quick Push Tests" 2>&1 | Out-Null
    & git -C $work config commit.gpgsign false 2>&1 | Out-Null

    if (-not $NoRemote) {
        $bare = Join-Path $base "origin.git"
        & git init --bare --quiet $bare 2>&1 | Out-Null
        & git -C $work remote add origin $bare 2>&1 | Out-Null
    }

    if (-not $NoCommit) {
        Set-Content -LiteralPath (Join-Path $work "a.txt") -Value "a1" -NoNewline
        Set-Content -LiteralPath (Join-Path $work "b.txt") -Value "b1" -NoNewline
        & git -C $work add -A 2>&1 | Out-Null
        & git -C $work commit --quiet -m "base" 2>&1 | Out-Null
    }

    return $work
}

function Remove-TestRepos {
    foreach ($path in $script:TempRoots) {
        try { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop } catch { }
    }
}

function Write-File {
    param([string]$Repo, [string]$Name, [string]$Content)
    $full = Join-Path $Repo $Name
    $dir = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-Content -LiteralPath $full -Value $Content -NoNewline
}

function Staged {
    param([string]$Repo)
    $paths = Get-StagedPath -RepoPath $Repo
    return ($paths | Sort-Object)
}

function CommitCount {
    param([string]$Repo)
    $result = Invoke-Git -RepoPath $Repo -Arguments @("rev-list", "--count", "HEAD")
    if ($result.ExitCode -ne 0) { return 0 }
    return [int]$result.Text.Trim()
}

# A recorder for the three dialog callbacks, so a test can assert on what the
# user would have been shown as well as on what git ended up doing.
function New-Dialogs {
    param(
        $MessageToReturn = $null,   # $null means the user pressed Cancel
        [bool]$ApproveRisk = $true
    )

    $state = [pscustomobject]@{
        Notifications = New-Object System.Collections.ArrayList
        AskCalls      = New-Object System.Collections.ArrayList
        RiskCalls     = New-Object System.Collections.ArrayList
        Message       = $MessageToReturn
        Approve       = $ApproveRisk
    }

    $state | Add-Member -MemberType ScriptProperty -Name LastText -Value {
        if ($this.Notifications.Count -eq 0) { return "" }
        return $this.Notifications[$this.Notifications.Count - 1].Text
    }

    $state | Add-Member -MemberType NoteProperty -Name Ask -Value {
        param($summary, $count, $default)
        [void]$state.AskCalls.Add([pscustomobject]@{ Summary = $summary; Count = $count; Default = $default })
        return $state.Message
    }.GetNewClosure()

    $state | Add-Member -MemberType NoteProperty -Name Risk -Value {
        param($hits)
        [void]$state.RiskCalls.Add(@($hits))
        return $state.Approve
    }.GetNewClosure()

    $state | Add-Member -MemberType NoteProperty -Name Notify -Value {
        param($text, $kind)
        [void]$state.Notifications.Add([pscustomobject]@{ Text = $text; Kind = $kind })
    }.GetNewClosure()

    return $state
}

function Invoke-WithDialogs {
    param([string]$Repo, $Dialogs)
    return (Invoke-CommitPush -Path $Repo -AskMessage $Dialogs.Ask -ConfirmRisk $Dialogs.Risk -Notify $Dialogs.Notify)
}

# ===========================================================================
Write-Host ""
Write-Host "Quick Push tests" -ForegroundColor White

# ---------------------------------------------------------------------------
Group "Get-SensitiveReason - names that should stop a one-click push"

Assert-Equal "environment file"  (Get-SensitiveReason ".env")                      "bare .env"
Assert-Equal "environment file"  (Get-SensitiveReason "config/.env.production")    ".env with a suffix, in a subfolder"
Assert-Equal "environment file"  (Get-SensitiveReason "deploy/prod.env")           "*.env"
Assert-Equal "private SSH key"   (Get-SensitiveReason "keys/id_rsa")               "id_rsa"
Assert-Null                      (Get-SensitiveReason "keys/id_rsa.pub")           "id_rsa.pub is the half meant to be shared"
Assert-Equal "SSH configuration" (Get-SensitiveReason "home/.ssh/config")          "anything under .ssh"
Assert-Equal "private key or certificate" (Get-SensitiveReason "certs/server.pem") "*.pem"
Assert-Equal "private key"       (Get-SensitiveReason "secrets\api.key")           "backslash path is normalised"
Assert-Equal "database file"     (Get-SensitiveReason "db/clients.sqlite")         "*.sqlite"
Assert-Equal "service-account key" (Get-SensitiveReason "serviceAccount.json")     "match is case-insensitive"
Assert-Equal "credentials file"  (Get-SensitiveReason ".aws/credentials")          "credentials with no extension"
Assert-Equal "may hold an npm token" (Get-SensitiveReason ".npmrc")                ".npmrc"
Assert-Null                      (Get-SensitiveReason "src/app.js")                "ordinary source file"
Assert-Null                      (Get-SensitiveReason "README.md")                 "ordinary document"
Assert-Null                      (Get-SensitiveReason "docs/environment.md")       "a name that merely mentions environment"
Assert-Null                      (Get-SensitiveReason "doc/परिचय.txt")             "non-ASCII name is not sensitive by accident"

# A single hit has to arrive as a one-element list, not as the bare object.
# PSCustomObject has no .Count, so when this collapsed the caller's
# `if ($sensitive.Count -gt 0)` read $null and waved the .env straight through.
$oneHit = Get-SensitiveStagedFile -Paths @("src/app.js", ".env")
Assert-Equal 1 $oneHit.Count "a single hit still has a usable .Count"
Assert-Equal ".env" $oneHit[0].Path "and is still indexable"
Assert-Equal 0 (Get-SensitiveStagedFile -Paths @("src/app.js")).Count "no hits is an empty list, not null"

$hits = Get-SensitiveStagedFile -Paths @("src/app.js", ".env", "README.md", "certs/a.pfx")
Assert-Equal 2 $hits.Count "Get-SensitiveStagedFile finds both and only both"
Assert-Sequence @(".env", "certs/a.pfx") ($hits | ForEach-Object { $_.Path }) "reported in the order they were staged"
Assert-True ((Format-SensitiveWarning -Hits $hits) -match "certs/a\.pfx  -  certificate with private key") "warning text names the file and why"

# ---------------------------------------------------------------------------
Group "Get-StagedPathFromPorcelainZ - what will actually be committed"

Assert-Sequence @("a.txt") (Get-StagedPathFromPorcelainZ "M  a.txt`0") "staged modification"
Assert-Sequence @() (Get-StagedPathFromPorcelainZ " M a.txt`0") "worktree-only modification is not staged"
Assert-Sequence @() (Get-StagedPathFromPorcelainZ "?? new.txt`0") "untracked file is not staged"
Assert-Sequence @() (Get-StagedPathFromPorcelainZ "!! ignored.txt`0") "ignored file is not staged"
Assert-Sequence @("a.txt", "c.txt") (Get-StagedPathFromPorcelainZ "M  a.txt`0 M b.txt`0A  c.txt`0?? d.txt`0") "mixed record stream"
Assert-Sequence @("new name.txt") (Get-StagedPathFromPorcelainZ "R  new name.txt`0old name.txt`0") "rename reports the destination, not the source"
Assert-Sequence @("new.txt", "z.txt") (Get-StagedPathFromPorcelainZ "R  new.txt`0old.txt`0A  z.txt`0") "the record after a rename is not mistaken for a status line"
Assert-Sequence @("dir with spaces/a b.txt") (Get-StagedPathFromPorcelainZ "A  dir with spaces/a b.txt`0") "spaces are kept"
Assert-Sequence @("परिचय.txt") (Get-StagedPathFromPorcelainZ "A  परिचय.txt`0") "non-ASCII path survives -z intact"
Assert-Sequence @() (Get-StagedPathFromPorcelainZ "") "empty output"

# ---------------------------------------------------------------------------
Group "Get-PushArgument / Get-DefaultRemote - where a push goes"

Assert-Sequence @("push") (Get-PushArgument -HasUpstream $true -Branch "main" -Remote "origin") "branch with an upstream"
Assert-Sequence @("push", "--set-upstream", "origin", "feature/x") (Get-PushArgument -HasUpstream $false -Branch "feature/x" -Remote "origin") "new branch gets --set-upstream"
Assert-Null (Get-PushArgument -HasUpstream $false -Branch "HEAD" -Remote "origin") "detached HEAD has nothing to push"
Assert-Null (Get-PushArgument -HasUpstream $false -Branch "main" -Remote "") "no remote, nowhere to push"

Assert-Equal "origin" (Get-DefaultRemote -Remotes @("upstream", "origin")) "origin wins when present"
Assert-Equal "fork"   (Get-DefaultRemote -Remotes @("fork"))               "a single remote is used"
Assert-Null           (Get-DefaultRemote -Remotes @("fork", "upstream"))   "two remotes and no origin is a guess not worth making"
Assert-Null           (Get-DefaultRemote -Remotes @())                     "no remotes"

# ---------------------------------------------------------------------------
Group "Get-ParsedDiff - the side-by-side view in Git Status"

$simple = @"
diff --git a/a.txt b/a.txt
index 111..222 100644
--- a/a.txt
+++ b/a.txt
@@ -3 +3 @@
-old line
+new line
"@
$parsed = @(Get-ParsedDiff -RawDiff $simple)
Assert-Equal 1 $parsed.Count "one file"
Assert-Equal "a.txt" $parsed[0].Path "path taken from the b/ side"
Assert-Equal "Modified" $parsed[0].Status "status"
Assert-Equal 3 $parsed[0].Hunks[0].OldStart "hunk start with no count defaults to 1 line"
Assert-Sequence @("old line") $parsed[0].Hunks[0].OldLines "removed line"
Assert-Sequence @("new line") $parsed[0].Hunks[0].NewLines "added line"

$added = @"
diff --git a/new.txt b/new.txt
new file mode 100644
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,2 @@
+one
+two
"@
$parsed = @(Get-ParsedDiff -RawDiff $added)
Assert-Equal "Added" $parsed[0].Status "--- /dev/null means the file is new"
Assert-Sequence @("one", "two") $parsed[0].Hunks[0].NewLines "both added lines"

$binary = @"
diff --git a/logo.png b/logo.png
index 111..222 100644
Binary files a/logo.png and b/logo.png differ
"@
Assert-True (@(Get-ParsedDiff -RawDiff $binary)[0].Binary) "binary file is flagged"

# Regression: a changed line whose own text starts with -- or ++ used to be
# swallowed by the ---/+++ header check and vanish from the diff table.
$dashes = @"
diff --git a/args.txt b/args.txt
index 111..222 100644
--- a/args.txt
+++ b/args.txt
@@ -1,2 +1,2 @@
---legacy-flag
--- three dashes
+++new-flag
+++ three plusses
"@
$parsed = @(Get-ParsedDiff -RawDiff $dashes)
Assert-Sequence @("--legacy-flag", "-- three dashes") $parsed[0].Hunks[0].OldLines "removed lines starting with -- are kept"
Assert-Sequence @("++new-flag", "++ three plusses") $parsed[0].Hunks[0].NewLines "added lines starting with ++ are kept"

$multi = @"
diff --git a/one.txt b/one.txt
--- a/one.txt
+++ b/one.txt
@@ -1 +1 @@
-x
+y
@@ -9,2 +9,1 @@
-p
-q
+r
diff --git a/two.txt b/two.txt
--- a/two.txt
+++ b/two.txt
@@ -5 +5 @@
-m
+n
"@
$parsed = @(Get-ParsedDiff -RawDiff $multi)
Assert-Equal 2 $parsed.Count "two files"
Assert-Equal 2 $parsed[0].Hunks.Count "two hunks in the first file"
Assert-Equal 9 $parsed[0].Hunks[1].OldStart "second hunk start"
Assert-Equal 2 $parsed[0].Hunks[1].OldCount "second hunk count"
Assert-Equal "two.txt" $parsed[1].Path "second file"
Assert-Equal "" (Get-ParsedDiff -RawDiff "" | Out-String).Trim() "empty diff parses to nothing"

# ---------------------------------------------------------------------------
Group "Cancel puts the staging area back (the bug this pass is about)"

$repo = New-TestRepo
Write-File $repo "a.txt" "a2"
Write-File $repo "b.txt" "b2"
Write-File $repo "notes.txt" "scratch"
& git -C $repo add a.txt 2>&1 | Out-Null          # a hand-built partial staging

$before = Staged $repo
Assert-Sequence @("a.txt") $before "only a.txt is staged before Quick Push runs"

$dialogs = New-Dialogs -MessageToReturn $null      # the user presses Cancel
$code = Invoke-WithDialogs -Repo $repo -Dialogs $dialogs

Assert-Equal 0 $code "cancelling is not an error"
Assert-Sequence @("a.txt") (Staged $repo) "the partial staging survives Cancel"
Assert-Equal 1 (CommitCount $repo) "nothing was committed"
Assert-Equal "b2" (Get-Content -LiteralPath (Join-Path $repo "b.txt") -Raw) "the working tree is untouched"
Assert-True (Test-Path -LiteralPath (Join-Path $repo "notes.txt")) "the untracked file is still there"
Assert-Equal 1 $dialogs.AskCalls.Count "the commit dialog was shown once"
Assert-Equal 3 $dialogs.AskCalls[0].Count "and told how many files would be committed"

# write-tree/read-tree restores staged *content*, which a path-by-path reset
# cannot: here a.txt is staged as a2 and then changed again on disk to a3.
$repo = New-TestRepo
Write-File $repo "a.txt" "a2"
& git -C $repo add a.txt 2>&1 | Out-Null
Write-File $repo "a.txt" "a3"

$code = Invoke-WithDialogs -Repo $repo -Dialogs (New-Dialogs -MessageToReturn $null)
$stagedContent = (Invoke-Git -RepoPath $repo -Arguments @("show", ":a.txt")).Text
Assert-Equal "a2" $stagedContent "the staged version, not the worktree version, is what comes back"
Assert-Equal "a3" (Get-Content -LiteralPath (Join-Path $repo "a.txt") -Raw) "and the worktree keeps the newer text"

# The fallback path, used when write-tree refuses during a merge: unstage only
# what Quick Push added, leaving the user's own staged work alone.
$repo = New-TestRepo
Write-File $repo "a.txt" "a2"
Write-File $repo "c.txt" "c1"
& git -C $repo add a.txt 2>&1 | Out-Null
$stagedBefore = Staged $repo
& git -C $repo add -A 2>&1 | Out-Null
$restored = Restore-QuickPushIndex -RepoPath $repo -Snapshot $null -StagedBefore $stagedBefore
Assert-True $restored "fallback restore reports success"
Assert-Sequence @("a.txt") (Staged $repo) "fallback unstages only what was added"

# ---------------------------------------------------------------------------
Group "The ordinary path: commit and push"

$repo = New-TestRepo
Write-File $repo "a.txt" "a2"
Write-File $repo "new.txt" "hello"
$dialogs = New-Dialogs -MessageToReturn "a real message"
$code = Invoke-WithDialogs -Repo $repo -Dialogs $dialogs

Assert-Equal 0 $code "success"
Assert-Equal 2 (CommitCount $repo) "one new commit"
Assert-Equal "a real message" (Invoke-Git -RepoPath $repo -Arguments @("log", "-1", "--pretty=%s")).Text "the message the user typed"
Assert-Sequence @() (Staged $repo) "nothing left staged"
Assert-True ($dialogs.LastText -match "pushed") "the user is told it was pushed"
Assert-Equal "Info" $dialogs.Notifications[0].Kind "reported as information, not an error"

$remoteHead = (Invoke-Git -RepoPath $repo -Arguments @("rev-parse", "origin/main")).Text.Trim()
$localHead = (Invoke-Git -RepoPath $repo -Arguments @("rev-parse", "HEAD")).Text.Trim()
Assert-Equal $localHead $remoteHead "the remote really has the commit"

# An empty message falls back to the generated default rather than failing.
$repo = New-TestRepo
Write-File $repo "a.txt" "a2"
$code = Invoke-WithDialogs -Repo $repo -Dialogs (New-Dialogs -MessageToReturn "   ")
Assert-True ((Invoke-Git -RepoPath $repo -Arguments @("log", "-1", "--pretty=%s")).Text -match "^Update \d{4}-\d{2}-\d{2}") "blank message becomes the dated default"

# ---------------------------------------------------------------------------
Group "A branch with no upstream is pushed, not refused"

$repo = New-TestRepo
& git -C $repo checkout --quiet -b feature/new 2>&1 | Out-Null
Write-File $repo "a.txt" "a2"
$dialogs = New-Dialogs -MessageToReturn "on a new branch"
$code = Invoke-WithDialogs -Repo $repo -Dialogs $dialogs

Assert-Equal 0 $code "success"
$upstream = (Invoke-Git -RepoPath $repo -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")).Text.Trim()
Assert-Equal "origin/feature/new" $upstream "the upstream was set as part of the push"
Assert-True ($dialogs.LastText -notmatch "fatal") "no raw git error text reached the user"

# ---------------------------------------------------------------------------
Group "Nowhere to push to is explained, not dumped as git output"

$repo = New-TestRepo -NoRemote
Write-File $repo "a.txt" "a2"
$dialogs = New-Dialogs -MessageToReturn "local only"
$code = Invoke-WithDialogs -Repo $repo -Dialogs $dialogs

Assert-Equal 0 $code "not treated as a failure"
Assert-Equal 2 (CommitCount $repo) "the commit is still made"
Assert-True ($dialogs.LastText -match "no remote configured") "the message says why nothing was pushed"
Assert-True ($dialogs.LastText -match "git remote add origin") "and how to fix it"

$repo = New-TestRepo -NoRemote
& git -C $repo remote add fork "https://example.invalid/fork.git" 2>&1 | Out-Null
& git -C $repo remote add upstream "https://example.invalid/up.git" 2>&1 | Out-Null
Write-File $repo "a.txt" "a2"
$dialogs = New-Dialogs -MessageToReturn "ambiguous remotes"
$code = Invoke-WithDialogs -Repo $repo -Dialogs $dialogs
Assert-True ($dialogs.LastText -match "several remotes") "two remotes and no origin is explained"
Assert-Equal 2 (CommitCount $repo) "the commit is still made"

# ---------------------------------------------------------------------------
Group "Credential-shaped filenames need a second look"

$repo = New-TestRepo
Write-File $repo ".env" "API_TOKEN=live-secret"
Write-File $repo "src/app.js" "console.log(1)"
$dialogs = New-Dialogs -MessageToReturn "adds a .env" -ApproveRisk $false
$code = Invoke-WithDialogs -Repo $repo -Dialogs $dialogs

Assert-Equal 1 $dialogs.RiskCalls.Count "the user was warned"
Assert-Sequence @(".env") ($dialogs.RiskCalls[0] | ForEach-Object { $_.Path }) "about the .env and nothing else"
Assert-Equal 0 $dialogs.AskCalls.Count "and was not asked for a commit message after declining"
Assert-Equal 1 (CommitCount $repo) "nothing was committed"
Assert-Sequence @() (Staged $repo) "and the index is back to empty"
Assert-True (Test-Path -LiteralPath (Join-Path $repo ".env")) "the file itself is left alone"

# Approving goes ahead - the check is a prompt to look, not a wall.
$repo = New-TestRepo
Write-File $repo "config/.env.production" "SECRET=1"
$dialogs = New-Dialogs -MessageToReturn "yes I meant it" -ApproveRisk $true
$code = Invoke-WithDialogs -Repo $repo -Dialogs $dialogs
Assert-Equal 1 $dialogs.RiskCalls.Count "still warned"
Assert-Equal 2 (CommitCount $repo) "but the commit is made when the user says so"

# A repository of ordinary files never sees the warning.
$repo = New-TestRepo
Write-File $repo "src/app.js" "console.log(1)"
$dialogs = New-Dialogs -MessageToReturn "ordinary work"
$code = Invoke-WithDialogs -Repo $repo -Dialogs $dialogs
Assert-Equal 0 $dialogs.RiskCalls.Count "no warning for ordinary files"

# ---------------------------------------------------------------------------
Group "Nothing to commit"

$repo = New-TestRepo
$dialogs = New-Dialogs -MessageToReturn "should not be asked"
$code = Invoke-WithDialogs -Repo $repo -Dialogs $dialogs
Assert-Equal 0 $dialogs.AskCalls.Count "no commit dialog when there is nothing to commit"
Assert-True ($dialogs.LastText -match "no commits yet|up to date|Pushed") "the user is told which of the three cases it is"

# Clean tree, but commits the remote has not seen: push them.
$repo = New-TestRepo
& git -C $repo push --quiet --set-upstream origin main 2>&1 | Out-Null
Write-File $repo "a.txt" "a2"
& git -C $repo add -A 2>&1 | Out-Null
& git -C $repo commit --quiet -m "made outside Quick Push" 2>&1 | Out-Null

$dialogs = New-Dialogs -MessageToReturn "should not be asked"
$code = Invoke-WithDialogs -Repo $repo -Dialogs $dialogs
Assert-Equal 0 $dialogs.AskCalls.Count "still no commit dialog"
Assert-True ($dialogs.LastText -match "pushed 1 unpushed commit") "the pending commit was pushed"
$remoteHead = (Invoke-Git -RepoPath $repo -Arguments @("rev-parse", "origin/main")).Text.Trim()
Assert-Equal (Invoke-Git -RepoPath $repo -Arguments @("rev-parse", "HEAD")).Text.Trim() $remoteHead "remote caught up"

# A brand-new repository with nothing in it at all.
$repo = New-TestRepo -NoCommit -NoRemote
$dialogs = New-Dialogs -MessageToReturn "should not be asked"
$code = Invoke-WithDialogs -Repo $repo -Dialogs $dialogs
Assert-True ($dialogs.LastText -match "no commits yet") "an empty repository says so instead of failing"

# ---------------------------------------------------------------------------
Group "Failures are reported, not swallowed"

$missing = Join-Path $env:TEMP ("quickpush-gone-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$dialogs = New-Dialogs -MessageToReturn "x"
$code = Invoke-CommitPush -Path $missing -AskMessage $dialogs.Ask -ConfirmRisk $dialogs.Risk -Notify $dialogs.Notify
Assert-Equal 1 $code "a folder that no longer exists is an error"
Assert-Equal "Error" $dialogs.Notifications[0].Kind "shown as an error"
Assert-True ($dialogs.LastText -match "no longer exists") "and says so in words"

$plain = Join-Path $env:TEMP ("quickpush-plain-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $plain | Out-Null
[void]$script:TempRoots.Add($plain)
$dialogs = New-Dialogs -MessageToReturn "x"
$code = Invoke-CommitPush -Path $plain -AskMessage $dialogs.Ask -ConfirmRisk $dialogs.Risk -Notify $dialogs.Notify
Assert-Equal 1 $code "a folder that is not a repository is an error"
Assert-True ($dialogs.LastText -match "not a Git repository") "with the original wording"

# A rejected commit leaves the staging area alone: the user will want to fix
# the cause and try again, and unstaging their work would be the wrong half of
# "cancel".
$repo = New-TestRepo
$hookDir = Join-Path $repo ".git\hooks"
Set-Content -LiteralPath (Join-Path $hookDir "pre-commit") -Value "#!/bin/sh`nexit 1`n"
Write-File $repo "a.txt" "a2"
$dialogs = New-Dialogs -MessageToReturn "will be rejected"
$code = Invoke-WithDialogs -Repo $repo -Dialogs $dialogs
Assert-Equal 1 $code "a rejected commit is an error"
Assert-Equal 1 (CommitCount $repo) "no commit was made"
Assert-Sequence @("a.txt") (Staged $repo) "the staged work is still there to retry"
Assert-True ($dialogs.LastText -match "Commit failed") "and the user is told"

# ---------------------------------------------------------------------------
Group "Shipped scripts parse"

foreach ($file in @(
    "scripts\commit-push.ps1", "scripts\git-status.ps1", "scripts\init-repo.ps1",
    "scripts\lib\quickpush-core.ps1", "scripts\lib\quickpush-commit.ps1",
    "simple-install\register-menu.ps1", "simple-install\unregister-menu.ps1"
)) {
    $full = Join-Path $root $file
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        Fail $file (@($errors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join "`n")
    } else {
        Ok $file
    }
}

# ---------------------------------------------------------------------------
Group "The lib is reachable from where it is dot-sourced, and gets installed"

# A dot-source of a path that does not exist is a runtime failure in a window
# that closes before it can be read, so the paths are checked here instead.
foreach ($script in @("scripts\commit-push.ps1", "scripts\git-status.ps1", "scripts\init-repo.ps1")) {
    $full = Join-Path $root $script
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$null, [ref]$null)
    $dotSourced = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot
    }, $true))

    Assert-True ($dotSourced.Count -ge 1) "$script dot-sources the lib"
    foreach ($command in $dotSourced) {
        # Each is `. (Join-Path $PSScriptRoot "lib\<file>")`, so the literal
        # tail of the expression is the path relative to scripts\.
        $text = $command.Extent.Text
        if ($text -match '"(lib\\[^"]+)"') {
            $target = Join-Path (Split-Path -Parent $full) $Matches[1]
            Assert-True (Test-Path -LiteralPath $target) "$script -> $($Matches[1]) exists"
        } else {
            Fail $script "dot-source is not the expected `. (Join-Path `$PSScriptRoot `"lib\...`")` shape: $text"
        }
    }
}

# Both installers copy scripts\ into %LOCALAPPDATA%\QuickPush. A lib\ they do
# not copy is the "I changed it and nothing happened" trap that review.md warns
# about, except worse: the script dies instead of running the old code.
$registerText = Get-Content -LiteralPath (Join-Path $root "simple-install\register-menu.ps1") -Raw
Assert-True ($registerText -match 'lib') "register-menu.ps1 installs lib\"
$installText = Get-Content -LiteralPath (Join-Path $root "install.bat") -Raw
Assert-True ($installText -match 'INSTALL_DIR%\\lib') "install.bat installs lib\"
Assert-True ($installText -match 'quickpush_cmdline\.c') "install.bat compiles the new module"

# ---------------------------------------------------------------------------
Group "Shell extension command line (C)"

$cTest = Join-Path $PSScriptRoot "cmdline_test.c"
$cSrc = Join-Path $root "shell-extension\quickpush_cmdline.c"
$gcc = (Get-Command gcc -ErrorAction SilentlyContinue)
if (-not $gcc) { $gcc = (Get-Command "D:\TDM-GCC-64\bin\gcc.exe" -ErrorAction SilentlyContinue) }

if (-not $gcc) {
    Skip "cmdline_test.c" "no gcc on PATH"
} else {
    $exe = Join-Path $PSScriptRoot "cmdline_test.exe"
    $build = & $gcc.Source -std=c99 -Wall -o $exe $cTest $cSrc 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail "cmdline_test.c (build)" ($build | Out-String)
    } else {
        $out = & $exe 2>&1
        $exit = $LASTEXITCODE
        foreach ($line in @($out)) {
            $text = [string]$line
            if ($text -match "^ok   (.*)$")   { Ok $Matches[1] }
            elseif ($text -match "^FAIL (.*)$") { Fail $Matches[1] "" }
            elseif ($text) { Write-Host "         $text" -ForegroundColor DarkGray }
        }
        if ($exit -ne 0 -and $script:Failed -eq 0) { Fail "cmdline_test.exe" "exited $exit with no failure reported" }
        Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
Remove-TestRepos

Write-Host ""
if ($script:Failed -eq 0) {
    Write-Host "  $($script:Passed) passed, $($script:Skipped) skipped" -ForegroundColor Green
    Write-Host ""
    exit 0
} else {
    Write-Host "  $($script:Passed) passed, $($script:Failed) FAILED, $($script:Skipped) skipped" -ForegroundColor Red
    Write-Host ""
    exit 1
}
