# Gitea Automation Scripts

A collection of PowerShell and Bash automation scripts for managing Gitea Organizations at scale e.g. covering branch hygiene, branch standardisation, and AI-assisted README generation.

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Scripts](#scripts)
  - [gitea/gitea\_branch\_analyzer.ps1](#giteagitea_branch_analyzerps1)
  - [gitea/gitea\_standardize\_branch\_names.ps1](#giteagitea_standardize_branch_namesps1)
  - [gitea/gitea\_prep\_org\_for\_genai.ps1](#giteagitea_prep_org_for_genаips1) ⚡ GenAI
  - [gitea/gitea\_org\_genai\_readme.ps1](#giteagitea_org_genai_readmeps1) ⚡ GenAI
- [GenAI Workflow](#genai-workflow)
- [Common Parameters](#common-parameters)

---

## Overview

[Gitea](https://github.com/go-gitea/gitea) is a painless self-hosted all-in-one software development service, including Git hosting, code review, team collaboration, package registry and CI/CD.

All scripts target the **Gitea REST API v1** and are designed to operate across every active (non-archived) repository in a given organisation. They share a consistent set of parameters and support self-signed SSL certificates for on-premises Gitea instances.

Two of the four scripts interact directly with **GitHub Copilot** (via the `gh copilot` CLI) to use a large language model for automated README generation — these are marked ⚡ GenAI below.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| PowerShell 5.1 or PowerShell 7+ | All scripts support both versions |
| Gitea personal access token | Must have read/write access to the target organisation |
| `git` on the system `PATH` | Required by the GenAI README generator |
| `gh` CLI authenticated to Gitea | Required by GenAI scripts only — access to the chosen model (e.g. `gpt-4.1`) must be available |

---

## Scripts

### gitea/gitea_branch_analyzer.ps1

**Purpose:** Audits every active repository in the organisation and reports any that contain branches other than the standard set (`main`, `master`, `develop`). Useful for identifying stale branches, non-standard branching strategies, or leftover feature/hotfix branches.

**Key behaviours:**
- Pages through all repositories and all branches via the Gitea API.
- Skips archived repositories automatically.
- Produces a console summary table and optionally exports results to a CSV file.

**Parameters:**

| Parameter | Required | Description |
|---|---|---|
| `-BaseUrl` | Yes | Gitea server base URL |
| `-Organization` | Yes | Organisation name |
| `-Token` | Yes | Gitea personal access token |
| `-SkipCertificateCheck` | No | Bypass SSL validation (self-signed certs) |
| `-ExportCsv` | No | Save results to a CSV file |

**Example:**
```powershell
.\gitea_branch_analyzer.ps1 `
    -BaseUrl "https://gitea.example.com" `
    -Organization "my-org" `
    -Token "your_token" `
    -SkipCertificateCheck `
    -ExportCsv
```

---

### gitea/gitea_standardize_branch_names.ps1

**Purpose:** Enforces a consistent default-branch naming convention across the organisation by renaming `master` → `main` and ensuring `main`/`develop` branches are lowercase. Also updates the repository's default branch setting in Gitea to reflect any rename.

**Key behaviours:**
- Supports `-WhatIf` for a full dry-run preview before any changes are applied.
- Skips repositories where branches are already correctly named.
- Optionally exports a per-repository results CSV.

**Parameters:**

| Parameter | Required | Description |
|---|---|---|
| `-BaseUrl` | Yes | Gitea server base URL |
| `-Organization` | Yes | Organisation name |
| `-Token` | Yes | Gitea personal access token |
| `-SkipCertificateCheck` | No | Bypass SSL validation (self-signed certs) |
| `-WhatIf` | No | Preview changes without applying them |
| `-ExportCsv` | No | Save results to a CSV file |

**Example:**
```powershell
# Dry-run first
.\gitea_standardize_branch_names.ps1 `
    -BaseUrl "https://gitea.example.com" `
    -Organization "my-org" `
    -Token "your_token" `
    -SkipCertificateCheck `
    -WhatIf

# Apply changes
.\gitea_standardize_branch_names.ps1 `
    -BaseUrl "https://gitea.example.com" `
    -Organization "my-org" `
    -Token "your_token" `
    -SkipCertificateCheck
```

---

### gitea/gitea_prep_org_for_genai.ps1 ⚡ GenAI

> **This script is step 1 of the GenAI README workflow.** It does not call an AI model itself but prepares repositories for the AI generation step.

**Purpose:** Tags every active, non-archived repository in the organisation with the Gitea topic `needs-readme`, which acts as a processing flag for the companion script `gitea_org_genai_readme.ps1`. Repositories on the built-in exception list (configurable inside the script) are skipped.

**Key behaviours:**
- Reads existing topics for each repository and only adds `needs-readme` if it is not already present.
- Supports `-WhatIf` for a dry-run preview.
- Contains a hardcoded `$ExceptionList` array (editable in the script) to permanently exclude specific repositories.

**Parameters:**

| Parameter | Required | Description |
|---|---|---|
| `-BaseUrl` | Yes | Gitea server base URL |
| `-Organization` | Yes | Organisation name |
| `-Token` | Yes | Gitea personal access token |
| `-SkipCertificateCheck` | No | Bypass SSL validation (self-signed certs) |
| `-WhatIf` | No | Preview which repos would be tagged |

**Example:**
```powershell
# Preview
.\gitea_prep_org_for_genai.ps1 `
    -BaseUrl "https://gitea.example.com" `
    -Organization "my-org" `
    -Token "your_token" `
    -SkipCertificateCheck `
    -WhatIf

# Apply
.\gitea_prep_org_for_genai.ps1 `
    -BaseUrl "https://gitea.example.com" `
    -Organization "my-org" `
    -Token "your_token" `
    -SkipCertificateCheck
```

---

### gitea/gitea_org_genai_readme.ps1 ⚡ GenAI

> **This script is step 2 of the GenAI README workflow and is the primary AI-powered script in this repository.**

**Purpose:** For every repository tagged with `needs-readme`, clones (or pulls) it locally, invokes **`gh copilot`** with a carefully constructed prompt to generate or refresh a standardised `README.md`, then commits and pushes the result back to `main`. After a successful update the `needs-readme` topic is automatically removed.

**How the AI is used:**

The script calls `gh copilot --model <model> --allow-all-tools --deny-tool 'shell(git*)'` with a detailed prompt that instructs the model to:

1. Scan the repository source files to understand the codebase.
2. Write accurate, project-specific content for each section.
3. Infer the application type (API, web app, service, desktop, Android, library, console) from Gitea topics and tailor the **Deployment Process** section accordingly.
4. Preserve the **System Owner and System Manager** section verbatim if real names are already present.
5. Use a fixed set of heading names — the model is explicitly prohibited from renaming any heading.

The Gitea repo's `git` access is intentionally denied to the agent (`--deny-tool 'shell(git*)'`) so it cannot commit, push, or alter history directly; all VCS operations are handled by the script itself after a safety check that validates only `README.md` was modified.

**README structure produced:**
```
# <Repository Name>
## Overview
## System Owner and System Manager
## Installation
## Deployment Process
## Troubleshooting
```

**Key behaviours:**
- Supports `-WhatIf` to preview which repositories would be processed without cloning or invoking the model.
- Performs a post-generation safety check: if the AI modified any file other than `README.md`, all changes are reset and the repository is marked as failed.
- The `-DontPushToGit` switch allows local testing without pushing changes.
- Produces a final summary table with per-repository status: `Updated`, `Failed`, `Skipped`, or `Would Update (WhatIf)`.

**Parameters:**

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-BaseUrl` | Yes | — | Gitea server base URL |
| `-Organization` | Yes | — | Organisation name |
| `-Token` | Yes | — | Gitea personal access token |
| `-LocalPath` | No | Current directory | Local folder to clone repositories into |
| `-SkipCertificateCheck` | No | `false` | Bypass SSL validation (self-signed certs) |
| `-WhatIf` | No | `false` | Preview without cloning or calling the model |
| `-Model` | No | `gpt-4.1` | `gh copilot` model identifier |
| `-DontPushToGit` | No | `false` | Run AI generation locally without pushing |

**Example:**
```powershell
# Preview which repos would be updated
.\gitea_org_genai_readme.ps1 `
    -BaseUrl "https://gitea.example.com" `
    -Organization "my-org" `
    -Token "your_token" `
    -SkipCertificateCheck `
    -WhatIf

# Generate and push READMEs
.\gitea_org_genai_readme.ps1 `
    -BaseUrl "https://gitea.example.com" `
    -Organization "my-org" `
    -Token "your_token" `
    -LocalPath "C:\temp\readme-gen" `
    -SkipCertificateCheck

# Use a different model
.\gitea_org_genai_readme.ps1 `
    -BaseUrl "https://gitea.example.com" `
    -Organization "my-org" `
    -Token "your_token" `
    -Model "gpt-4o" `
    -SkipCertificateCheck
```

---

## GenAI Workflow

The two GenAI scripts are designed to be run in sequence:

```
Step 1 — Tag repositories
.\gitea_prep_org_for_genai.ps1 ...
  └─ Adds "needs-readme" topic to every qualifying repository

Step 2 — Generate READMEs
.\gitea_org_genai_readme.ps1 ...
  └─ For each repo tagged "needs-readme":
       1. Clone / pull the repository
       2. Infer application type from topics
       3. Call gh copilot to edit README.md
       4. Verify only README.md was changed
       5. Commit and push to main
       6. Remove the "needs-readme" topic
```

Re-running step 2 is safe: repositories already processed will have the topic removed and will be skipped.

---

## Common Parameters

All scripts share these parameters:

| Parameter | Description |
|---|---|
| `-BaseUrl` | Full URL to the Gitea instance, e.g. `https://gitea.example.com` |
| `-Organization` | The Gitea organisation slug |
| `-Token` | A Gitea personal access token with appropriate read/write permissions |
| `-SkipCertificateCheck` | Disables SSL certificate validation — use only in trusted on-premises environments with self-signed certificates |
