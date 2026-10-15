<#
    Quick Push - core logic.

    Everything in this file decides something. Nothing in it draws anything:
    no WinForms, no colours, no dialogs. The three scripts in scripts\ are the
    WinForms half and pass their dialogs in as script blocks, which is what
    makes this half testable - tests\run.ps1 drives Invoke-CommitPush against a
    real throwaway repository with callbacks that answer without a screen.

    Dot-source it:  . (Join-Path $PSScriptRoot "lib\quickpush-core.ps1")
#>

# ---------------------------------------------------------------------------
# Running git
# ---------------------------------------------------------------------------

<#
    Runs git in $RepoPath and returns its exit code and output together.

    Uses `git -C` rather than Set-Location so that nothing here depends on, or
    changes, the caller's working directory - a script that Set-Locations into
    a folder Explorer has since deleted dies with a raw PowerShell error before
    it can show a themed one.

    $ErrorActionPreference is forced to Continue for the duration: with 2>&1 on
    a native command, a caller running under "Stop" turns any line git writes
    to stderr into a terminating NativeCommandError, even when git exits 0.
#>
function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $saved = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw = & git -C $RepoPath @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }

    $lines = @($raw | ForEach-Object { [string]$_ })
    [pscustomobject]@{
        ExitCode = $code
        Lines    = $lines
        Text     = ($lines -join "`n")
        # -z output carries no newlines, so joining with nothing reassembles
        # the NUL-separated record stream exactly as git wrote it.
        Raw      = ($lines -join "")
    }
}

function Test-GitRepository {
    param([Parameter(Mandatory = $true)][string]$RepoPath)
    if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) { return $false }
    return (Invoke-Git -RepoPath $RepoPath -Arguments @("rev-parse", "--is-inside-work-tree")).ExitCode -eq 0
}

# ---------------------------------------------------------------------------
# The index snapshot
# ---------------------------------------------------------------------------

<#
    The current index as a tree object id, or $null if one cannot be taken.

    This is what makes Cancel mean cancel. Quick Push runs `git add -A` before
    it can show you what it is about to commit, so by the time the dialog
    appears a partial staging the user built by hand is already gone; pressing
    Escape has to put it back.

    write-tree/read-tree restores the index exactly, including the staged
    content of a file that was modified again afterwards - a path-by-path
    `git reset HEAD -- <file>` cannot do that, because it resets to HEAD rather
    than to what was staged. write-tree refuses while a merge is in progress,
    which is why Restore-QuickPushIndex has a second-best path.
#>
function Get-IndexSnapshot {
    param([Parameter(Mandatory = $true)][string]$RepoPath)
    $result = Invoke-Git -RepoPath $RepoPath -Arguments @("write-tree")
    if ($result.ExitCode -ne 0) { return $null }
    $tree = $result.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($tree)) { return $null }
    return $tree
}

# Every function here that returns a list returns it as ,@(...). Without the
# comma PowerShell unrolls the result: a one-element list arrives as the bare
# element, and a PSCustomObject has no .Count, so `if ($x.Count -gt 0)` at the
# call site silently reads $null and does nothing. That is exactly how the
# credential-name warning failed to fire the first time it was tested.
function Get-StagedPath {
    param([Parameter(Mandatory = $true)][string]$RepoPath)
    $result = Invoke-Git -RepoPath $RepoPath -Arguments @("diff", "--cached", "--name-only", "-z")
    if ($result.ExitCode -ne 0) { return ,@() }
    return ,@($result.Raw -split "`0" | Where-Object { $_ })
}

<#
    Puts the index back the way Get-IndexSnapshot found it.

    Returns $true if the index was restored. When there was no snapshot to
    restore - a merge was in progress - it falls back to unstaging only the
    paths `git add -A` introduced, which leaves the user's own staged work
    alone even though a file that was staged and then modified again keeps the
    newer content. Returns $false if even that failed, so the caller can say so
    rather than silently leaving a rewritten index behind.
#>
function Restore-QuickPushIndex {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [string]$Snapshot,
        [string[]]$StagedBefore = @()
    )

    if ($Snapshot) {
        return (Invoke-Git -RepoPath $RepoPath -Arguments @("read-tree", $Snapshot)).ExitCode -eq 0
    }

    # Assigned first, not piped: these functions hand back one array object,
    # which a pipeline would pass along whole instead of element by element.
    $stagedNow = Get-StagedPath -RepoPath $RepoPath
    $added = @($stagedNow | Where-Object { $StagedBefore -notcontains $_ })
    if ($added.Count -eq 0) { return $true }
    return (Invoke-Git -RepoPath $RepoPath -Arguments (@("reset", "--quiet", "HEAD", "--") + $added)).ExitCode -eq 0
}

# ---------------------------------------------------------------------------
# Reading status
# ---------------------------------------------------------------------------

<#
    The paths `git status --porcelain -z` reports as staged.

    -z is used rather than the plain short form because plain porcelain output
    quotes any path that is not printable ASCII - a Devanagari or accented
    filename arrives as "\340\244\225..." and no filename check can match it.
    With -z, paths are emitted verbatim and separated by NUL.

    A rename or copy record is followed by a second record holding the source
    path; that one is consumed here and not reported, because the file that
    will be committed is the destination.
#>
function Get-StagedPathFromPorcelainZ {
    param([string]$PorcelainZ)

    $records = @(($PorcelainZ -split "`0") | Where-Object { $_ })
    $paths = New-Object System.Collections.ArrayList

    for ($i = 0; $i -lt $records.Count; $i++) {
        $record = $records[$i]
        if ($record.Length -lt 4) { continue }   # "XY p" is the shortest valid record

        $x = $record.Substring(0, 1)
        $path = $record.Substring(3)

        if ($x -eq "R" -or $x -eq "C") { $i++ }  # skip the source-path record
        if ($x -eq " " -or $x -eq "?" -or $x -eq "!") { continue }

        [void]$paths.Add($path)
    }
    return ,@($paths)
}

# ---------------------------------------------------------------------------
# Files that should probably not be published
# ---------------------------------------------------------------------------

<#
    Filename shapes that are usually a secret or a private data file.

    Quick Push is one click from a public GitHub repository, and `git add -A`
    picks up anything .gitignore does not cover - the .env created ten minutes
    ago, the key dropped in the folder to test with. The list is deliberately
    about *names*, not contents: it is a prompt to look, not a scanner, and a
    false positive costs one extra click.

    Patterns are matched against the file's leaf name with -like, except those
    containing a slash, which are matched against the whole forward-slashed
    path.
#>
$script:QuickPushSensitivePattern = @(
    @{ Pattern = ".env";                   Reason = "environment file" }
    @{ Pattern = ".env.*";                 Reason = "environment file" }
    @{ Pattern = "*.env";                  Reason = "environment file" }
    @{ Pattern = "id_rsa";                 Reason = "private SSH key" }
    @{ Pattern = "id_dsa";                 Reason = "private SSH key" }
    @{ Pattern = "id_ecdsa";               Reason = "private SSH key" }
    @{ Pattern = "id_ed25519";             Reason = "private SSH key" }
    @{ Pattern = "*/.ssh/*";               Reason = "SSH configuration" }
    @{ Pattern = ".ssh/*";                 Reason = "SSH configuration" }
    @{ Pattern = "*.pem";                  Reason = "private key or certificate" }
    @{ Pattern = "*.pfx";                  Reason = "certificate with private key" }
    @{ Pattern = "*.p12";                  Reason = "certificate with private key" }
    @{ Pattern = "*.ppk";                  Reason = "PuTTY private key" }
    @{ Pattern = "*.key";                  Reason = "private key" }
    @{ Pattern = "*.keystore";             Reason = "Java keystore" }
    @{ Pattern = "*.jks";                  Reason = "Java keystore" }
    @{ Pattern = "credentials";            Reason = "credentials file" }
    @{ Pattern = "credentials.*";          Reason = "credentials file" }
    @{ Pattern = "*credentials.json";      Reason = "credentials file" }
    @{ Pattern = "secrets";                Reason = "secrets file" }
    @{ Pattern = "secrets.*";              Reason = "secrets file" }
    @{ Pattern = "*.secret";               Reason = "secrets file" }
    @{ Pattern = "secring.*";              Reason = "GPG secret keyring" }
    @{ Pattern = ".netrc";                 Reason = "stored login" }
    @{ Pattern = "_netrc";                 Reason = "stored login" }
    @{ Pattern = ".npmrc";                 Reason = "may hold an npm token" }
    @{ Pattern = ".pypirc";                Reason = "may hold a PyPI token" }
    @{ Pattern = "serviceaccount*.json";   Reason = "service-account key" }
    @{ Pattern = "*service-account*.json"; Reason = "service-account key" }
    @{ Pattern = "*.sqlite";               Reason = "database file" }
    @{ Pattern = "*.sqlite3";              Reason = "database file" }
    @{ Pattern = "*.mdf";                  Reason = "database file" }
    @{ Pattern = "*.sql.gz";               Reason = "database dump" }
)

<#
    The reason $Path looks sensitive, or $null if it does not.

    A .pub alongside a private key is the public half and is meant to be
    shared, so it is excluded before anything else is tried.
#>
function Get-SensitiveReason {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalised = $Path -replace "\\", "/"
    $leaf = $normalised.Substring($normalised.LastIndexOf("/") + 1)

    if ($leaf -like "*.pub") { return $null }

    foreach ($entry in $script:QuickPushSensitivePattern) {
        $pattern = $entry.Pattern
        $subject = if ($pattern.Contains("/")) { $normalised } else { $leaf }
        if ($subject -like $pattern) { return $entry.Reason }
    }
    return $null
}

function Get-SensitiveStagedFile {
    param([string[]]$Paths = @())

    $hits = New-Object System.Collections.ArrayList
    foreach ($path in $Paths) {
        $reason = Get-SensitiveReason -Path $path
        if ($reason) {
            [void]$hits.Add([pscustomobject]@{ Path = $path; Reason = $reason })
        }
    }
    return ,@($hits)
}

function Format-SensitiveWarning {
    param([object[]]$Hits = @())
    return (@($Hits | ForEach-Object { "  $($_.Path)  -  $($_.Reason)" }) -join "`n")
}

# ---------------------------------------------------------------------------
# Pushing
# ---------------------------------------------------------------------------

<#
    The git arguments that push the current branch, or $null when no push is
    possible.

    A branch with no upstream cannot be pushed by a bare `git push` - git exits
    with a wall of advice text about --set-upstream, which the original showed
    to the user verbatim. Supplying it directly is what the user wanted anyway:
    they clicked a button called "Commit & Push".

    Detached HEAD has no branch to set an upstream for, and no remote means
    there is nowhere to push at all; both come back as $null.
#>
function Get-PushArgument {
    param(
        [bool]$HasUpstream,
        [string]$Branch,
        [string]$Remote
    )

    if ($HasUpstream) { return ,@("push") }
    if (-not $Remote) { return $null }
    if (-not $Branch -or $Branch -eq "HEAD") { return $null }
    return ,@("push", "--set-upstream", $Remote, $Branch)
}

<#
    Which remote to push a new branch to: origin if it exists, otherwise the
    only remote if there is exactly one, otherwise $null - guessing between
    several named remotes is how a commit ends up on the wrong fork.
#>
function Get-DefaultRemote {
    param([string[]]$Remotes = @())
    $names = @($Remotes | Where-Object { $_ })
    if ($names -contains "origin") { return "origin" }
    if ($names.Count -eq 1) { return $names[0] }
    return $null
}

function Get-RepositoryState {
    param([Parameter(Mandatory = $true)][string]$RepoPath)

    $branchResult = Invoke-Git -RepoPath $RepoPath -Arguments @("rev-parse", "--abbrev-ref", "HEAD")
    $branch = if ($branchResult.ExitCode -eq 0) { $branchResult.Text.Trim() } else { "" }

    $upstreamResult = Invoke-Git -RepoPath $RepoPath -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    $hasUpstream = ($upstreamResult.ExitCode -eq 0)
    $upstream = if ($hasUpstream) { $upstreamResult.Text.Trim() } else { "" }

    $remoteResult = Invoke-Git -RepoPath $RepoPath -Arguments @("remote")
    $remotes = if ($remoteResult.ExitCode -eq 0) { @($remoteResult.Lines | Where-Object { $_ }) } else { @() }

    # An unborn branch - `git init` with nothing committed yet - has a branch
    # name but no HEAD to push, and rev-list against it fails rather than
    # returning zero, so it has to be asked about separately.
    $hasCommits = (Invoke-Git -RepoPath $RepoPath -Arguments @("rev-parse", "--verify", "--quiet", "HEAD")).ExitCode -eq 0

    [pscustomobject]@{
        Branch      = $branch
        HasCommits  = $hasCommits
        HasUpstream = $hasUpstream
        Upstream    = $upstream
        Remotes     = $remotes
        Remote      = (Get-DefaultRemote -Remotes $remotes)
    }
}

# ---------------------------------------------------------------------------
# The diff shown by git-status.ps1
# ---------------------------------------------------------------------------

<#
    Parses `git diff -U0` output into per-file hunks of plain old/new line
    lists, without pulling in a diff library. -U0 means zero context, so every
    +/- line left inside a hunk is a real change.

    Header lines are only recognised before the first @@ of a file. They used
    to be recognised anywhere, which silently dropped any changed line whose
    own text began with "--" or "++": inside a hunk, a removed line reading
    "--legacy" arrives as "---legacy" and was mistaken for the ---/+++ file
    header.
#>
function Get-ParsedDiff {
    param([string]$RawDiff)

    $files = New-Object System.Collections.ArrayList
    $current = $null
    $currentHunk = $null

    foreach ($line in ($RawDiff -split "`r?`n")) {
        if ($line -match '^diff --git a/(.+) b/(.+)$') {
            if ($current) { [void]$files.Add($current) }
            $current = [pscustomobject]@{
                Path   = $Matches[2]
                Status = "Modified"
                Binary = $false
                Hunks  = New-Object System.Collections.ArrayList
            }
            $currentHunk = $null
            continue
        }
        if ($null -eq $current) { continue }

        if ($line -match '^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@') {
            $currentHunk = [pscustomobject]@{
                OldStart = [int]$Matches[1]
                OldCount = if ($Matches[2]) { [int]$Matches[2] } else { 1 }
                NewStart = [int]$Matches[3]
                NewCount = if ($Matches[4]) { [int]$Matches[4] } else { 1 }
                OldLines = New-Object System.Collections.ArrayList
                NewLines = New-Object System.Collections.ArrayList
            }
            [void]$current.Hunks.Add($currentHunk)
            continue
        }

        if ($null -eq $currentHunk) {
            # Still in the per-file header block, where ---/+++ mean what they say.
            if ($line -like "Binary files*")   { $current.Binary = $true; continue }
            if ($line -match '^--- (.+)$')     { if ($Matches[1] -eq "/dev/null") { $current.Status = "Added" }; continue }
            if ($line -match '^\+\+\+ (.+)$')  { if ($Matches[1] -eq "/dev/null") { $current.Status = "Deleted" }; continue }
            continue
        }

        if ($line.StartsWith("-")) { [void]$currentHunk.OldLines.Add($line.Substring(1)); continue }
        if ($line.StartsWith("+")) { [void]$currentHunk.NewLines.Add($line.Substring(1)); continue }
    }
    if ($current) { [void]$files.Add($current) }
    return $files
}
