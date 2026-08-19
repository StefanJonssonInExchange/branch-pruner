#Requires -Version 5.1
<#
.SYNOPSIS
    Prune merged git branches across many repositories — locally and/or on GitHub.

.DESCRIPTION
    Two independent modes, selected with -Local and/or -Remote (pass both for "both"):

      -Local   Scans configured root folder(s) for git clones, runs `git fetch --prune`,
               and flags local branches that are either:
                 * gone   — their upstream tracking branch was deleted on the server
                            (catches squash-merged PRs that `git branch --merged` misses)
                 * merged — fully merged into the repo's default branch
               Uses your cached git credentials only to fetch. Deletes local branches only.

      -Remote  Not filesystem based. Asks GitHub for *your merged PRs* in the configured
               org(s) — i.e. "every repo you've contributed to" — and offers to delete the
               head branches that still exist on the server. Uses your `gh` keyring auth.

    Each candidate is tagged so you can see WHY it was flagged.

    Safety: protected branches (main/master/develop/...), the repo default branch, and the
    currently checked-out branch are never offered. Local branches that are gone-but-not-merged
    require -Force (a `git branch -D`). Nothing is deleted without confirmation unless -Yes.

.PARAMETER Local
    Prune local merged branches in your cloned repositories.

.PARAMETER Remote
    Prune remote branches of your merged GitHub PRs. Pass with -Local for both.

.PARAMETER Init
    Interactively create/update the config file (scan roots + GitHub orgs), then exit.

.PARAMETER DryRun
    List what would be deleted and stop. Deletes nothing.

.PARAMETER DeleteAll
    Skip the interactive selection and target every flagged branch.

.PARAMETER Yes
    Skip the final "are you sure?" confirmation.

.PARAMETER Force
    Also delete local branches that are gone-upstream but NOT merged into the default branch
    (these would otherwise be skipped because they may contain unpushed work).

.PARAMETER NoFetch
    Skip `git fetch --prune` in local mode (faster / offline; "gone" detection may be stale).

.PARAMETER Org
    Override the GitHub org(s) for remote mode (defaults to config).

.PARAMETER Root
    Override the local scan root folder(s) for this run (defaults to config).

.PARAMETER RepoFilter
    Only consider repositories whose name matches this wildcard (e.g. 'hubix-*').

.PARAMETER ConfigPath
    Path to the config file (default: %USERPROFILE%\.branch-pruner\config.json).

.PARAMETER MaxDepth
    How deep to search for repos under each local root (default 6).

.EXAMPLE
    .\prune-branches.ps1 -Init
    First-time setup: choose scan roots and GitHub orgs.

.EXAMPLE
    .\prune-branches.ps1 -Local
    Find local merged branches everywhere, then pick which to delete.

.EXAMPLE
    .\prune-branches.ps1 -Remote -DryRun
    Preview the server-side branches of your merged PRs without deleting.

.EXAMPLE
    .\prune-branches.ps1 -Local -Remote -DeleteAll -Yes
    Non-interactive full cleanup (local + remote), no prompts.
#>
[CmdletBinding()]
param(
    [switch]$Local,
    [switch]$Remote,
    [switch]$Init,
    [switch]$DryRun,
    [switch]$DeleteAll,
    [switch]$Yes,
    [switch]$Force,
    [switch]$NoFetch,
    [string[]]$Org,
    [string[]]$Root,
    [string]$RepoFilter,
    [string]$ConfigPath,
    [int]$MaxDepth = 6
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Native exit codes are inspected per-call via Invoke-Git/.Code and Invoke-Gh (which throws),
# not via $PSNativeCommandUseErrorActionPreference — many git probes here exit non-zero by design.

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
$DefaultConfigPath = Join-Path $env:USERPROFILE '.branch-pruner\config.json'
$DefaultProtected  = @('HEAD', 'main', 'master', 'develop', 'dev', 'trunk', 'release/*')

# ---------------------------------------------------------------------------
# Low-level helpers
# ---------------------------------------------------------------------------
function Invoke-Git {
    # Runs git in a repo, returns @{ Output = <string[]>; Code = <int> }.
    param([string]$Repo, [string[]]$Arguments)
    $out  = & git -C $Repo @Arguments 2>&1
    $code = $LASTEXITCODE
    [pscustomobject]@{ Output = @($out | ForEach-Object { "$_" }); Code = $code }
}

function Invoke-Gh {
    # Runs gh with GITHUB_TOKEN cleared (the scopeless env var breaks auth — use keyring).
    # Returns stdout as a single string. Throws on non-zero exit.
    param([string[]]$Arguments)
    $hadToken = Test-Path Env:\GITHUB_TOKEN
    $saved    = if ($hadToken) { $env:GITHUB_TOKEN } else { $null }
    if ($hadToken) { Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue }
    try {
        $out  = & gh @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        if ($hadToken) { $env:GITHUB_TOKEN = $saved }
    }
    if ($code -ne 0) {
        throw "gh $($Arguments -join ' ') failed (exit $code): $(($out | ForEach-Object { "$_" }) -join "`n")"
    }
    return (@($out | Where-Object { $_ -is [string] }) -join "`n")
}

function Invoke-GhLines {
    param([string[]]$Arguments)
    $text = Invoke-Gh -Arguments $Arguments
    if (-not $text) { return @() }
    return @($text -split "`r?`n" | Where-Object { $_ -ne '' })
}

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-Protected {
    param([string]$Branch, [string[]]$Patterns)
    foreach ($p in $Patterns) { if ($Branch -like $p) { return $true } }
    return $false
}

function Get-Prop {
    # StrictMode-safe property access: returns $null instead of throwing on a missing property.
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj.PSObject.Properties.Name -contains $Name) { return $Obj.$Name }
    return $null
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
function Get-Config {
    param([string]$Path)
    if (-not $Path) { $Path = $DefaultConfigPath }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    }
    catch {
        Write-Warning "Config at $Path is invalid JSON: $($_.Exception.Message)"
        return $null
    }
}

function Save-Config {
    param([object]$Config, [string]$Path)
    if (-not $Path) { $Path = $DefaultConfigPath }
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
    Write-Host "Saved config to " -NoNewline; Write-Host $Path -ForegroundColor Cyan
}

function Invoke-Init {
    param([string]$Path)
    if (-not $Path) { $Path = $DefaultConfigPath }
    Write-Host "branch-pruner setup" -ForegroundColor Cyan
    Write-Host "-------------------"
    $existing = Get-Config -Path $Path

    # --- Local roots ---
    $defaultRoot = Join-Path $env:USERPROFILE 'source\repos'
    $existingRoots = Get-Prop (Get-Prop $existing 'local') 'roots'
    if ($existingRoots) { $defaultRoot = ($existingRoots -join '; ') }
    Write-Host ""
    Write-Host "Local scan root folder(s) — where your git clones live."
    Write-Host "Separate multiple paths with ';'."
    $rootsIn = Read-Host "Roots [$defaultRoot]"
    if (-not $rootsIn) { $rootsIn = $defaultRoot }
    $roots = @($rootsIn -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    # --- Orgs ---
    $orgGuess = @()
    if (Test-CommandExists 'gh') {
        try { $orgGuess = @(Invoke-GhLines @('api', 'user/orgs', '--jq', '.[].login')) } catch { }
    }
    $existingOrgs = Get-Prop (Get-Prop $existing 'remote') 'orgs'
    if ($existingOrgs) { $orgGuess = @($existingOrgs) }
    $defaultOrgs = ($orgGuess -join '; ')
    Write-Host ""
    Write-Host "GitHub org(s) for remote pruning — 'repos you've contributed to' is scoped to these."
    if ($orgGuess.Count) { Write-Host ("Detected: {0}" -f ($orgGuess -join ', ')) -ForegroundColor DarkGray }
    $orgsIn = Read-Host "Orgs [$defaultOrgs]"
    if (-not $orgsIn) { $orgsIn = $defaultOrgs }
    $orgs = @($orgsIn -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    # --- Protected ---
    $protected = $DefaultProtected
    $existingProtected = Get-Prop $existing 'protectedBranches'
    if ($existingProtected) { $protected = @($existingProtected) }

    $config = [pscustomobject]@{
        local             = [pscustomobject]@{ roots = $roots }
        remote            = [pscustomobject]@{ orgs = $orgs }
        protectedBranches = $protected
    }
    Save-Config -Config $config -Path $Path
    Write-Host ""
    Write-Host "Done. Try:  " -NoNewline; Write-Host ".\prune-branches.ps1 -Local -DryRun" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Repo discovery (local)
# ---------------------------------------------------------------------------
function Find-GitRepos {
    param([string]$Root, [int]$MaxDepth = 6)
    $results = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $Root)) {
        Write-Warning "Root not found: $Root"
        return $results
    }
    $skip = @('node_modules', 'bin', 'obj', '.vs', 'packages', 'dist', '.next',
              '.svelte-kit', 'target', '.idea', '.terraform', '.angular')
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push([pscustomobject]@{ Path = (Resolve-Path -LiteralPath $Root).Path; Depth = 0 })
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        if (Test-Path -LiteralPath (Join-Path $cur.Path '.git')) {
            $results.Add($cur.Path)   # it's a repo — don't descend further
            continue
        }
        if ($cur.Depth -ge $MaxDepth) { continue }
        $children = $null
        try { $children = Get-ChildItem -LiteralPath $cur.Path -Directory -Force -ErrorAction Stop }
        catch { continue }
        foreach ($c in $children) {
            if ($skip -contains $c.Name) { continue }
            if ($c.Name.StartsWith('.') -and $c.Name -ne '.git') { continue }
            $stack.Push([pscustomobject]@{ Path = $c.FullName; Depth = $cur.Depth + 1 })
        }
    }
    return $results
}

function Get-DefaultBranch {
    param([string]$Repo)
    # origin/HEAD is the authoritative answer, but it is only set by `git clone` (or a manual
    # `git remote set-head`) — so clones made before the server renamed its default, and repos
    # added as a bare remote, won't have it. Fall back to guessing from well-known names.
    $r = Invoke-Git $Repo @('symbolic-ref', '--short', 'refs/remotes/origin/HEAD')
    if ($r.Code -eq 0 -and $r.Output.Count -gt 0 -and $r.Output[0]) {
        return ($r.Output[0] -replace '^origin/', '')
    }
    foreach ($b in @('main', 'master', 'trunk', 'develop')) {
        $r2 = Invoke-Git $Repo @('show-ref', '--verify', '--quiet', "refs/heads/$b")
        if ($r2.Code -eq 0) { return $b }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Candidate gathering
# ---------------------------------------------------------------------------
function New-Candidate {
    param($Mode, $RepoPath, $RepoName, $Branch, $Tags, [bool]$Force, $Detail)
    [pscustomobject]@{
        Mode     = $Mode
        RepoPath = $RepoPath
        RepoName = $RepoName
        Branch   = $Branch
        Tags     = $Tags        # array of @{ Text; Color }
        Force    = $Force
        Detail   = $Detail
    }
}

function Get-LocalCandidates {
    param([string[]]$Roots, [string[]]$Protected, [switch]$NoFetch, [string]$RepoFilter, [int]$MaxDepth)
    $out = [System.Collections.Generic.List[object]]::new()

    $repos = [System.Collections.Generic.List[string]]::new()
    foreach ($root in $Roots) { foreach ($r in (Find-GitRepos -Root $root -MaxDepth $MaxDepth)) { $repos.Add($r) } }
    $repos = @($repos | Sort-Object -Unique)
    if ($RepoFilter) { $repos = @($repos | Where-Object { (Split-Path $_ -Leaf) -like $RepoFilter }) }

    Write-Host ("Scanning {0} local repo(s)..." -f $repos.Count) -ForegroundColor DarkGray
    $i = 0
    foreach ($repo in $repos) {
        $i++
        $name = Split-Path $repo -Leaf
        Write-Progress -Activity 'Local scan' -Status $name -PercentComplete ([int](100 * $i / [Math]::Max(1, $repos.Count)))

        if (-not $NoFetch) {
            $fetch = Invoke-Git $repo @('fetch', '--prune', '--quiet')
            if ($fetch.Code -ne 0) {
                Write-Warning ("fetch failed in {0} (gone-detection may be stale): {1}" -f $name, (($fetch.Output -join ' ').Trim()))
            }
        }

        $def     = Get-DefaultBranch $repo
        $cur     = (Invoke-Git $repo @('rev-parse', '--abbrev-ref', 'HEAD')).Output | Select-Object -First 1
        $current = if ($cur) { $cur.Trim() } else { '' }

        # branches merged into default
        $mergedSet = @{}
        if ($def) {
            $mergeRef = $def
            if ((Invoke-Git $repo @('show-ref', '--verify', '--quiet', "refs/remotes/origin/$def")).Code -eq 0) {
                $mergeRef = "origin/$def"
            }
            $m = Invoke-Git $repo @('branch', '--merged', $mergeRef, '--format=%(refname:short)')
            if ($m.Code -eq 0) {
                foreach ($b in $m.Output) { if ($b -and $b.Trim()) { $mergedSet[$b.Trim()] = $true } }
            }
        }

        # all local branches + upstream tracking state
        $br = Invoke-Git $repo @('for-each-ref', '--format=%(refname:short)|%(upstream:track)', 'refs/heads')
        if ($br.Code -ne 0) { continue }
        foreach ($line in $br.Output) {
            if (-not $line) { continue }
            $parts = $line -split '\|', 2
            $bn    = $parts[0]
            $track = if ($parts.Count -gt 1) { $parts[1] } else { '' }
            if ($bn -eq $def -or $bn -eq $current) { continue }
            if (Test-Protected $bn $Protected) { continue }

            $gone   = ($track -eq '[gone]')
            $merged = $mergedSet.ContainsKey($bn)
            if (-not ($gone -or $merged)) { continue }

            $tags = @()
            if ($merged) { $tags += @{ Text = 'merged'; Color = 'Green' } }
            if ($gone)   { $tags += @{ Text = 'gone';   Color = 'Yellow' } }
            $needsForce = (-not $merged)   # gone but not merged → `git branch -D`
            if ($needsForce) { $tags += @{ Text = 'unmerged: needs -Force'; Color = 'Red' } }

            $out.Add( (New-Candidate -Mode 'local' -RepoPath $repo -RepoName $name -Branch $bn -Tags $tags -Force $needsForce -Detail $null) )
        }
    }
    Write-Progress -Activity 'Local scan' -Completed
    return $out
}

function Get-RemoteCandidates {
    param([string[]]$Orgs, [string[]]$Protected, [string]$RepoFilter)
    $out = [System.Collections.Generic.List[object]]::new()

    # 1) Discover repos where I have merged PRs (= repos I've contributed to), scoped to orgs.
    $repoSet = [ordered]@{}
    foreach ($org in $Orgs) {
        Write-Host ("Finding your merged PRs in {0}..." -f $org) -ForegroundColor DarkGray
        $json = Invoke-Gh @('search', 'prs', '--author=@me', '--merged', '--owner', $org, '--limit', '1000', '--json', 'repository')
        if ($json) {
            foreach ($pr in (ConvertFrom-Json $json)) {
                $nwo = $pr.repository.nameWithOwner
                if ($nwo) { $repoSet[$nwo] = $true }
            }
        }
    }
    $repos = @($repoSet.Keys)
    if ($RepoFilter) { $repos = @($repos | Where-Object { ($_ -split '/')[-1] -like $RepoFilter }) }
    Write-Host ("Checking {0} contributed repo(s)..." -f $repos.Count) -ForegroundColor DarkGray

    $i = 0
    foreach ($nwo in $repos) {
        $i++
        $rname = ($nwo -split '/')[-1]
        Write-Progress -Activity 'Remote scan' -Status $nwo -PercentComplete ([int](100 * $i / [Math]::Max(1, $repos.Count)))

        try {
            $def      = (Invoke-Gh @('repo', 'view', $nwo, '--json', 'defaultBranchRef', '--jq', '.defaultBranchRef.name')).Trim()
            $existing = @{}
            foreach ($b in (Invoke-GhLines @('api', "repos/$nwo/branches", '--paginate', '--jq', '.[].name'))) { $existing[$b] = $true }
            $prJson   = Invoke-Gh @('pr', 'list', '--repo', $nwo, '--author', '@me', '--state', 'merged', '--limit', '500', '--json', 'number,headRefName,url')
        }
        catch {
            Write-Warning "Skipping $nwo — $($_.Exception.Message)"
            continue
        }

        $prs = if ($prJson) { ConvertFrom-Json $prJson } else { @() }
        # group merged PRs by head branch; a branch may back several PRs
        $byBranch = @{}
        foreach ($pr in $prs) {
            $bn = $pr.headRefName
            if (-not $bn) { continue }
            if (-not $byBranch.ContainsKey($bn)) { $byBranch[$bn] = [System.Collections.Generic.List[object]]::new() }
            $byBranch[$bn].Add($pr)
        }

        foreach ($bn in $byBranch.Keys) {
            if (-not $existing.ContainsKey($bn)) { continue }     # already deleted on server
            if ($bn -eq $def) { continue }
            if (Test-Protected $bn $Protected) { continue }
            $nums   = @($byBranch[$bn] | ForEach-Object { "#$($_.number)" })
            $detail = "PR $($nums -join ', ') merged"
            $tags   = @(@{ Text = ($nums -join ',') + ' merged'; Color = 'Cyan' })
            $out.Add( (New-Candidate -Mode 'remote' -RepoPath $nwo -RepoName $rname -Branch $bn -Tags $tags -Force $false -Detail $detail) )
        }
    }
    Write-Progress -Activity 'Remote scan' -Completed
    return $out
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
function Write-Tags {
    param($Tags)
    foreach ($t in $Tags) {
        Write-Host ("[{0}]" -f $t.Text) -NoNewline -ForegroundColor $t.Color
        Write-Host ' ' -NoNewline
    }
}

function Show-Summary {
    param([object[]]$Candidates)
    $localN  = @($Candidates | Where-Object { $_.Mode -eq 'local' }).Count
    $remoteN = @($Candidates | Where-Object { $_.Mode -eq 'remote' }).Count
    Write-Host ""
    Write-Host ("Found {0} branch(es) to consider " -f $Candidates.Count) -NoNewline -ForegroundColor White
    Write-Host ("(local: {0}, remote: {1})" -f $localN, $remoteN) -ForegroundColor DarkGray

    foreach ($mode in @('local', 'remote')) {
        $group = @($Candidates | Where-Object { $_.Mode -eq $mode })
        if (-not $group.Count) { continue }
        Write-Host ""
        Write-Host ("== {0} ==" -f $mode.ToUpper()) -ForegroundColor Magenta
        foreach ($repoGrp in ($group | Group-Object RepoName | Sort-Object Name)) {
            Write-Host ("  {0}" -f $repoGrp.Name) -ForegroundColor White
            foreach ($c in $repoGrp.Group) {
                Write-Host "      - " -NoNewline -ForegroundColor DarkGray
                Write-Host $c.Branch -NoNewline
                Write-Host '  ' -NoNewline
                Write-Tags $c.Tags
                Write-Host ''
            }
        }
    }
}

function Format-CandidateLine {
    param($Candidate)
    $tagText = ($Candidate.Tags | ForEach-Object { "[$($_.Text)]" }) -join ' '
    return ("{0}/{1}  {2}" -f $Candidate.RepoName, $Candidate.Branch, $tagText)
}

# ---------------------------------------------------------------------------
# Interactive checkbox selector
# ---------------------------------------------------------------------------
function Select-TextFallback {
    param([object[]]$Items)
    Write-Host ""
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), (Format-CandidateLine $Items[$i]))
    }
    $resp = Read-Host "Enter numbers/ranges to delete (e.g. 1,3,5-8), 'all', or 'none'"
    if (-not $resp) { return @() }
    if ($resp -match '^\s*all\s*$') { return $Items }
    if ($resp -match '^\s*none\s*$') { return @() }
    $idx = New-Object System.Collections.Generic.HashSet[int]
    foreach ($tok in ($resp -split '[,\s]+' | Where-Object { $_ })) {
        if ($tok -match '^(\d+)-(\d+)$') {
            for ($k = [int]$Matches[1]; $k -le [int]$Matches[2]; $k++) { [void]$idx.Add($k) }
        }
        elseif ($tok -match '^\d+$') { [void]$idx.Add([int]$tok) }
    }
    return @($Items | Where-Object { $idx.Contains([array]::IndexOf($Items, $_) + 1) })
}

function Select-Interactive {
    param([object[]]$Items)
    if ($Items.Count -eq 0) { return @() }
    if ([Console]::IsInputRedirected) { return (Select-TextFallback -Items $Items) }

    $n       = $Items.Count
    $checked = New-Object 'bool[]' $n
    $pos     = 0
    $top     = 0
    try { $maxVisible = [Math]::Max(3, [Console]::WindowHeight - 7) } catch { $maxVisible = 15 }

    $prevCursor = $true
    try { $prevCursor = [Console]::CursorVisible } catch { }
    try { [Console]::CursorVisible = $false } catch { }

    $confirmed = $false
    try {
        while ($true) {
            if ($pos -lt $top) { $top = $pos }
            if ($pos -ge $top + $maxVisible) { $top = $pos - $maxVisible + 1 }

            [Console]::Clear()
            Write-Host "Select branches to delete" -ForegroundColor Cyan
            Write-Host "  up/down move  ·  space toggle  ·  a all  ·  n none  ·  enter confirm  ·  esc cancel" -ForegroundColor DarkGray
            $selCount = @($checked | Where-Object { $_ }).Count
            Write-Host ("  {0} of {1} selected" -f $selCount, $n) -ForegroundColor White
            if ($top -gt 0) { Write-Host "    ^ more above" -ForegroundColor DarkGray } else { Write-Host "" }

            $end = [Math]::Min($n, $top + $maxVisible)
            for ($idx = $top; $idx -lt $end; $idx++) {
                $it     = $Items[$idx]
                $marker = if ($idx -eq $pos) { '>' } else { ' ' }
                $box    = if ($checked[$idx]) { '[x]' } else { '[ ]' }
                $boxCol = if ($checked[$idx]) { 'Green' } else { 'DarkGray' }
                Write-Host (" {0} " -f $marker) -NoNewline -ForegroundColor Cyan
                Write-Host $box -NoNewline -ForegroundColor $boxCol
                Write-Host (" {0}/" -f $it.RepoName) -NoNewline -ForegroundColor DarkGray
                $branchCol = if ($idx -eq $pos) { 'White' } else { 'Gray' }
                Write-Host $it.Branch -NoNewline -ForegroundColor $branchCol
                Write-Host '  ' -NoNewline
                Write-Tags $it.Tags
                Write-Host ''
            }
            if ($end -lt $n) { Write-Host "    v more below" -ForegroundColor DarkGray }

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'    { if ($pos -gt 0) { $pos-- } }
                'DownArrow'  { if ($pos -lt $n - 1) { $pos++ } }
                'PageUp'     { $pos = [Math]::Max(0, $pos - $maxVisible) }
                'PageDown'   { $pos = [Math]::Min($n - 1, $pos + $maxVisible) }
                'Home'       { $pos = 0 }
                'End'        { $pos = $n - 1 }
                'Spacebar'   { $checked[$pos] = -not $checked[$pos]; if ($pos -lt $n - 1) { $pos++ } }
                'Enter'      { $confirmed = $true }
                'Escape'     { $confirmed = $false; return @() }
                default {
                    switch ("$($key.KeyChar)".ToLower()) {
                        'a' { for ($j = 0; $j -lt $n; $j++) { $checked[$j] = $true } }
                        'n' { for ($j = 0; $j -lt $n; $j++) { $checked[$j] = $false } }
                        'q' { return @() }
                    }
                }
            }
            if ($confirmed) { break }
        }
    }
    finally {
        try { [Console]::CursorVisible = $prevCursor } catch { }
        [Console]::Clear()
    }

    $result = [System.Collections.Generic.List[object]]::new()
    for ($idx = 0; $idx -lt $n; $idx++) { if ($checked[$idx]) { $result.Add($Items[$idx]) } }
    return $result
}

# ---------------------------------------------------------------------------
# Deletion
# ---------------------------------------------------------------------------
function Remove-Branches {
    param([object[]]$ToDelete)
    $ok = 0; $fail = 0
    Write-Host ""
    foreach ($c in $ToDelete) {
        try {
            if ($c.Mode -eq 'local') {
                $flag = if ($c.Force) { '-D' } else { '-d' }
                $r = Invoke-Git $c.RepoPath @('branch', $flag, $c.Branch)
                if ($r.Code -ne 0) { throw (($r.Output -join ' ').Trim()) }
            }
            else {
                Invoke-Gh @('api', '-X', 'DELETE', "repos/$($c.RepoPath)/git/refs/heads/$($c.Branch)") | Out-Null
            }
            Write-Host "  deleted " -NoNewline -ForegroundColor Green
            Write-Host ("{0} {1}/{2}" -f $c.Mode, $c.RepoName, $c.Branch)
            $ok++
        }
        catch {
            Write-Host "  FAILED  " -NoNewline -ForegroundColor Red
            Write-Host ("{0}/{1} — {2}" -f $c.RepoName, $c.Branch, $_.Exception.Message) -ForegroundColor DarkGray
            $fail++
        }
    }
    Write-Host ""
    Write-Host ("Deleted {0}" -f $ok) -NoNewline -ForegroundColor Green
    if ($fail -gt 0) { Write-Host (", failed {0}" -f $fail) -ForegroundColor Red } else { Write-Host "." }
}

# ===========================================================================
# Main
# ===========================================================================
if ($Init) { Invoke-Init -Path $ConfigPath; return }

if (-not $Local -and -not $Remote) {
    Write-Host "Specify -Local and/or -Remote. See:  Get-Help .\prune-branches.ps1 -Detailed" -ForegroundColor Yellow
    Write-Host "First time?  Run:  .\prune-branches.ps1 -Init" -ForegroundColor Yellow
    return
}

if (-not (Test-CommandExists 'git')) { throw "git is not on PATH." }
if ($Remote -and -not (Test-CommandExists 'gh')) { throw "gh (GitHub CLI) is not on PATH — required for -Remote." }

$config = Get-Config -Path $ConfigPath
$protected = $DefaultProtected
$cfgProtected = Get-Prop $config 'protectedBranches'
if ($cfgProtected) { $protected = @($cfgProtected) }

$candidates = [System.Collections.Generic.List[object]]::new()

if ($Local) {
    $cfgRoots = Get-Prop (Get-Prop $config 'local') 'roots'
    $roots = @(if ($Root) { $Root } elseif ($cfgRoots) { $cfgRoots } else { @() })
    if (-not $roots -or $roots.Count -eq 0) {
        Write-Warning "No local scan roots configured. Run -Init or pass -Root <path>."
    }
    else {
        foreach ($c in (Get-LocalCandidates -Roots $roots -Protected $protected -NoFetch:$NoFetch -RepoFilter $RepoFilter -MaxDepth $MaxDepth)) {
            $candidates.Add($c)
        }
    }
}

if ($Remote) {
    $cfgOrgs = Get-Prop (Get-Prop $config 'remote') 'orgs'
    $orgs = @(if ($Org) { $Org } elseif ($cfgOrgs) { $cfgOrgs } else { @() })
    if (-not $orgs -or $orgs.Count -eq 0) {
        Write-Warning "No GitHub orgs configured. Run -Init or pass -Org <name>."
    }
    else {
        foreach ($c in (Get-RemoteCandidates -Orgs $orgs -Protected $protected -RepoFilter $RepoFilter)) {
            $candidates.Add($c)
        }
    }
}

if ($candidates.Count -eq 0) {
    Write-Host ""
    Write-Host "Nothing to prune. You're clean." -ForegroundColor Green
    return
}

Show-Summary -Candidates $candidates

if ($DryRun) {
    Write-Host ""
    Write-Host "(dry run — nothing deleted)" -ForegroundColor Yellow
    return
}

# --- choose what to delete ---
$toDelete = $null
if ($DeleteAll) {
    $toDelete = @($candidates)
}
elseif ([Console]::IsInputRedirected) {
    Write-Host ""
    Write-Host "Non-interactive session: re-run with -DeleteAll to delete, or -DryRun to preview." -ForegroundColor Yellow
    return
}
else {
    Write-Host ""
    Write-Host "What now?  " -NoNewline
    Write-Host "[A]" -NoNewline -ForegroundColor Cyan; Write-Host " delete all   " -NoNewline
    Write-Host "[S]" -NoNewline -ForegroundColor Cyan; Write-Host " select   " -NoNewline
    Write-Host "[Q]" -NoNewline -ForegroundColor Cyan; Write-Host " cancel"
    $k = [Console]::ReadKey($true)
    switch ("$($k.KeyChar)".ToLower()) {
        'a' { $toDelete = @($candidates) }
        's' { $toDelete = @(Select-Interactive -Items $candidates) }
        default { Write-Host "Cancelled." -ForegroundColor Yellow; return }
    }
}

# --- force gate for local unmerged branches ---
if (-not $Force) {
    $blocked = @($toDelete | Where-Object { $_.Mode -eq 'local' -and $_.Force })
    if ($blocked.Count -gt 0) {
        Write-Host ""
        Write-Host ("Skipping {0} unmerged local branch(es) (re-run with -Force to delete):" -f $blocked.Count) -ForegroundColor Yellow
        foreach ($b in $blocked) { Write-Host ("    {0}/{1}" -f $b.RepoName, $b.Branch) -ForegroundColor DarkGray }
        $toDelete = @($toDelete | Where-Object { -not ($_.Mode -eq 'local' -and $_.Force) })
    }
}

if (-not $toDelete -or $toDelete.Count -eq 0) {
    Write-Host "Nothing selected." -ForegroundColor Yellow
    return
}

# --- confirm ---
if (-not $Yes) {
    Write-Host ""
    $ans = Read-Host ("Delete {0} branch(es)? Type 'yes' to confirm" -f $toDelete.Count)
    if ($ans -notmatch '^\s*(y|yes)\s*$') { Write-Host "Cancelled." -ForegroundColor Yellow; return }
}

Remove-Branches -ToDelete $toDelete
