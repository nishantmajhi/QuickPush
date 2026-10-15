<#
    Quick Push - the "Commit & Push" sequence.

    This is the whole decision path of commit-push.ps1 with the dialogs lifted
    out into three script blocks the caller supplies. commit-push.ps1 passes in
    its themed WinForms dialogs; tests\run.ps1 passes in script blocks that
    answer from a table. Both drive exactly the same git.

    Requires quickpush-core.ps1 to have been dot-sourced first.
#>

<#
    Stages everything, asks, commits and pushes. Returns a process exit code.

    $AskMessage  is called with ($summary, $fileCount, $defaultMessage) and
                 returns the commit message, or $null to cancel.
    $ConfirmRisk is called with an array of {Path, Reason} for staged files
                 whose names look like secrets, and returns $true to go ahead.
    $Notify      is called with ($text, $kind) where $kind is "Info" or
                 "Error"; its return value is ignored.

    The order matters and is the point of the rewrite. The original staged
    everything, then showed the dialog, and on Cancel exited with the index
    rewritten. Here the index is photographed first and put back on every path
    that does not end in a commit.
#>
function Invoke-CommitPush {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$AskMessage,
        [Parameter(Mandatory = $true)][scriptblock]$ConfirmRisk,
        [Parameter(Mandatory = $true)][scriptblock]$Notify
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        & $Notify "This folder no longer exists, or cannot be opened:`n$Path" "Error"
        return 1
    }

    if (-not (Test-GitRepository -RepoPath $Path)) {
        & $Notify "This folder is not a Git repository:`n$Path" "Error"
        return 1
    }

    # Everything the user had staged before Quick Push ran. Both are captured:
    # the tree is the exact restore, the path list is what the fallback needs
    # when write-tree refuses because a merge is in progress.
    $snapshot = Get-IndexSnapshot -RepoPath $Path
    $stagedBefore = Get-StagedPath -RepoPath $Path

    $restore = {
        if (-not (Restore-QuickPushIndex -RepoPath $Path -Snapshot $snapshot -StagedBefore $stagedBefore)) {
            & $Notify ("Cancelled, but the staging area could not be put back the way it was.`n`n" +
                       "Check `git status` before committing anything here.") "Error"
        }
    }

    $add = Invoke-Git -RepoPath $Path -Arguments @("add", "-A")
    if ($add.ExitCode -ne 0) {
        & $restore
        & $Notify "Could not stage the changes in this folder:`n`n$($add.Text)" "Error"
        return 1
    }

    $statusResult = Invoke-Git -RepoPath $Path -Arguments @("status", "--porcelain", "-z")
    $stagedNow = Get-StagedPathFromPorcelainZ -PorcelainZ $statusResult.Raw

    if ($stagedNow.Count -eq 0) {
        & $restore
        return (Invoke-PushOnly -Path $Path -Notify $Notify)
    }

    $sensitive = Get-SensitiveStagedFile -Paths $stagedNow
    if ($sensitive.Count -gt 0) {
        if (-not (& $ConfirmRisk $sensitive)) {
            & $restore
            return 0
        }
    }

    $summary = (Invoke-Git -RepoPath $Path -Arguments @("status", "--short")).Text
    $defaultMessage = "Update " + (Get-Date -Format "yyyy-MM-dd HH:mm")

    $message = & $AskMessage $summary $stagedNow.Count $defaultMessage
    if ($null -eq $message) {
        & $restore
        return 0
    }
    if ([string]::IsNullOrWhiteSpace($message)) { $message = $defaultMessage }

    $commit = Invoke-Git -RepoPath $Path -Arguments @("commit", "-m", $message)
    if ($commit.ExitCode -ne 0) {
        # The index is deliberately left as it is. A commit that a hook or a
        # missing identity rejected is one the user still wants to make once
        # the cause is fixed; unstaging their work again would be the wrong
        # half of "cancel".
        & $Notify "Commit failed:`n`n$($commit.Text)" "Error"
        return 1
    }

    $state = Get-RepositoryState -RepoPath $Path
    $pushArgs = Get-PushArgument -HasUpstream $state.HasUpstream -Branch $state.Branch -Remote $state.Remote

    if ($null -eq $pushArgs) {
        & $Notify (Format-NoPushTargetMessage -State $state -Committed $true -Message $message) "Info"
        return 0
    }

    $push = Invoke-Git -RepoPath $Path -Arguments $pushArgs
    if ($push.ExitCode -eq 0) {
        $where = if ($state.HasUpstream) { $state.Upstream } else { "$($state.Remote)/$($state.Branch) (new upstream)" }
        & $Notify "Committed and pushed to $where.`n`nMessage: $message" "Info"
        return 0
    }

    & $Notify "Commit succeeded but PUSH FAILED:`n`n$($push.Text)" "Error"
    return 0
}

<#
    The nothing-to-commit path: there is no new work, so the only question left
    is whether the branch has commits the remote has not seen.
#>
function Invoke-PushOnly {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$Notify
    )

    $state = Get-RepositoryState -RepoPath $Path

    if (-not $state.HasCommits) {
        & $Notify "No changes to commit, and this repository has no commits yet.`n`n$Path" "Info"
        return 0
    }

    if ($state.HasUpstream) {
        $aheadResult = Invoke-Git -RepoPath $Path -Arguments @("rev-list", "--count", "@{u}..HEAD")
        $ahead = if ($aheadResult.ExitCode -eq 0) { $aheadResult.Text.Trim() } else { "0" }
        if ($ahead -eq "0") {
            & $Notify "Nothing to commit and nothing to push - already up to date with $($state.Upstream).`n`n$Path" "Info"
            return 0
        }

        $push = Invoke-Git -RepoPath $Path -Arguments @("push")
        if ($push.ExitCode -eq 0) {
            & $Notify "Nothing new to commit, but pushed $ahead unpushed commit(s) to $($state.Upstream)." "Info"
        } else {
            & $Notify "Nothing new to commit. Tried to push $ahead pending commit(s), but PUSH FAILED:`n`n$($push.Text)" "Error"
        }
        return 0
    }

    $pushArgs = Get-PushArgument -HasUpstream $false -Branch $state.Branch -Remote $state.Remote
    if ($null -eq $pushArgs) {
        & $Notify (Format-NoPushTargetMessage -State $state -Committed $false) "Info"
        return 0
    }

    $push = Invoke-Git -RepoPath $Path -Arguments $pushArgs
    if ($push.ExitCode -eq 0) {
        & $Notify "Nothing new to commit. Pushed $($state.Branch) to $($state.Remote) and set it as the upstream." "Info"
    } else {
        & $Notify "Nothing new to commit, and the push to $($state.Remote) FAILED:`n`n$($push.Text)" "Error"
    }
    return 0
}

<#
    Says why there is nowhere to push to, which is either that no remote is
    configured, that several are and none is called origin, or that HEAD is
    detached. The original showed git's own --set-upstream advice block for all
    three, which explains none of them.
#>
function Format-NoPushTargetMessage {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [bool]$Committed = $false,
        [string]$Message = ""
    )

    $head = if ($Committed) { "Committed locally, but nothing was pushed." } else { "No changes to commit, and nothing was pushed." }

    $why =
        if (-not $State.Branch -or $State.Branch -eq "HEAD") {
            "HEAD is detached, so there is no branch to push."
        } elseif ($State.Remotes.Count -eq 0) {
            "This repository has no remote configured. Add one with:`n`n  git remote add origin <url>"
        } else {
            "This repository has several remotes ($($State.Remotes -join ', ')) and none of them is called 'origin', " +
            "so Quick Push will not guess which one to push to. Set the upstream once with:`n`n" +
            "  git push --set-upstream <remote> $($State.Branch)"
        }

    $tail = if ($Committed -and $Message) { "`n`nMessage: $Message" } else { "" }
    return "$head`n`n$why$tail"
}
