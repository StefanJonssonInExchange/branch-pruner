# branch-pruner

A PowerShell CLI that cleans up **merged git branches** across many repositories — both your
local clones and the branches left behind on GitHub after a PR merges. It uses your existing
cached credentials (Git Credential Manager for `git`, the `gh` keyring for GitHub), so there's
nothing extra to log into.

## What it does

Two independent modes — pass `-Local`, `-Remote`, or both:

| Mode | Data source | What it deletes | "Merged" means |
|------|-------------|-----------------|----------------|
| `-Local` | Scans your configured folder(s) for git clones, runs `git fetch --prune` | **Local** branches | `gone` (upstream deleted on server — catches squash merges) **or** `merged` into the default branch |
| `-Remote` | Asks GitHub for **your merged PRs** in the configured org(s) — i.e. *every repo you've contributed to* | **Server-side** branches whose merged-PR head still exists | The PR is merged |

Every candidate is **tagged with why** it was flagged: `[merged]`, `[gone]`, or `[#123 merged]`.

## Requirements

- PowerShell 5.1+ (Windows PowerShell or `pwsh` 7)
- `git` on PATH
- `gh` (GitHub CLI), authenticated (`gh auth status`) — only needed for `-Remote`

## First run

```powershell
.\prune-branches.ps1 -Init
```

This writes a config to `%USERPROFILE%\.branch-pruner\config.json` with your local scan
root(s) and GitHub org(s). Re-run `-Init` any time to change it, or edit the JSON directly.

## Usage

```powershell
# Preview only — never deletes
.\prune-branches.ps1 -Local -DryRun
.\prune-branches.ps1 -Remote -DryRun

# Interactive: shows a checkbox list, you pick what to delete
.\prune-branches.ps1 -Local
.\prune-branches.ps1 -Local -Remote          # both at once

# Delete everything flagged, no prompts (CI / scripted cleanup)
.\prune-branches.ps1 -Local -Remote -DeleteAll -Yes

# Narrow the scope
.\prune-branches.ps1 -Local -RepoFilter 'hubix-*'
.\prune-branches.ps1 -Remote -Org SomeOrg
.\prune-branches.ps1 -Local -Root 'D:\work' -NoFetch
```

### Interactive selection keys

```
up/down  move      space  toggle      a  select all
                                       n  select none
enter    confirm   esc/q  cancel
```

(If the session isn't an interactive terminal, it falls back to typing numbers/ranges like `1,3,5-8`.)

## Flags

| Flag | Meaning |
|------|---------|
| `-Local` / `-Remote` | Choose mode(s). Pass both for "both". |
| `-Init` | Interactive config setup, then exit. |
| `-DryRun` | List candidates and stop. Deletes nothing. |
| `-DeleteAll` | Skip the picker; target every flagged branch. |
| `-Yes` | Skip the final confirmation prompt. |
| `-Force` | Also delete **local** branches that are `gone` but **not** merged (a `git branch -D`). |
| `-NoFetch` | Skip `git fetch --prune` in local mode (faster / offline; `gone` data may be stale). |
| `-Org <name...>` | Override GitHub org(s) for `-Remote`. |
| `-Root <path...>` | Override local scan root(s). |
| `-RepoFilter <wildcard>` | Only repos whose name matches (e.g. `hubix-*`). |
| `-ConfigPath <path>` | Use a non-default config file. |
| `-MaxDepth <n>` | How deep to search for repos under each root (default 6). |

`Get-Help .\prune-branches.ps1 -Detailed` has the full reference.

## Safety

- **Never deletes without confirmation** unless you pass `-DeleteAll -Yes`.
- The repo's **default branch**, the **currently checked-out branch**, and any **protected
  branch** pattern (`main`, `master`, `develop`, `release/*`, … — configurable) are never offered.
- Local branches that are `gone` but **not merged** into the default branch are **skipped**
  unless you pass `-Force` (they may contain unpushed work). They're clearly tagged in the list.
- `-Remote` only ever targets branches whose **own merged PR** still has a live head ref — it
  will not touch a branch that has no merged PR of yours.

## Sharing with colleagues

The tool is a single self-contained `.ps1` with no hardcoded paths — all machine-specific
settings live in each person's own `%USERPROFILE%\.branch-pruner\config.json`. A teammate just
copies `prune-branches.ps1`, runs `-Init` once, and they're set.

## Config file shape

```json
{
  "local":  { "roots": ["C:\\Users\\you\\source\\repos"] },
  "remote": { "orgs":  ["YourOrg"] },
  "protectedBranches": ["HEAD", "main", "master", "develop", "dev", "trunk", "release/*"]
}
```
