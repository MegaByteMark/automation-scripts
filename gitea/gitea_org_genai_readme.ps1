<#
.SYNOPSIS
    Gitea Organization GenAI README Generator

.DESCRIPTION
    Clones every repository in a Gitea organization to a local folder, uses
    gh copilot to generate (or refresh) a standardized README.md, preserves
    the existing sections verbatim if they have been completed, then
    commits and pushes the changes back to the main branch.

    README structure produced:
      # <App Name>
      ## Overview
      ## System Owner and System Manager
      ## Installation
      ## Deployment Process   (content varies by app type inferred from topics)
      ## Troubleshooting

    Pre-requisites:
    - The companion script "gitea_prep_org_for_genai.ps1" must have been run first to tag repositories with the "needs-readme" topic.
    - The gh CLI tool must be installed and authenticated with access to the Gitea server, and have access to the specified model (e.g. gpt-4.1).
    - Git must be installed and available in the system PATH.

.PARAMETER BaseUrl
    Gitea server base URL

.PARAMETER Organization
    Organization name

.PARAMETER Token
    Gitea personal access token (required)

.PARAMETER LocalPath
    Local folder to clone repositories into (default: current directory)

.PARAMETER SkipCertificateCheck
    Skip SSL certificate validation (for self-signed certificates)

.PARAMETER WhatIf
    Preview changes without committing or pushing

.PARAMETER Model
    gh copilot model to use (default: gpt-4.1)

.PARAMETER DontPushToGit
    (internal switch to disable pushing to git, used for testing)

.EXAMPLE
    .\gitea_autogenerate_readmes.ps1 -BaseUrl "https://your_gitea_server" -Organization "your_organization" -Token "your_token" -SkipCertificateCheck -WhatIf

.EXAMPLE
    .\gitea_autogenerate_readmes.ps1 -BaseUrl "https://your_gitea_server" -Organization "your_organization" -Token "your_token" -SkipCertificateCheck
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$Organization,

    [Parameter(Mandatory = $true)]
    [string]$Token,

    [Parameter(Mandatory = $false)]
    [string]$LocalPath = (Get-Location).Path,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCertificateCheck,
    
    [Parameter(Mandatory = $false)]
    [switch]$DontPushToGit = $false,

    [Parameter(Mandatory = $false)]
    [string]$Model = "gpt-4.1"
)

# ---------------------------------------------------------------------------
# Certificate handling
# ---------------------------------------------------------------------------
if ($SkipCertificateCheck) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $PSDefaultParameterValues['Invoke-RestMethod:SkipCertificateCheck'] = $true
        $PSDefaultParameterValues['Invoke-WebRequest:SkipCertificateCheck'] = $true
    }
    else {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
}

# ---------------------------------------------------------------------------
# API configuration
# ---------------------------------------------------------------------------
$ApiUrl = "$($BaseUrl.TrimEnd('/'))/api/v1"
$Headers = @{
    'Authorization' = "token $Token"
    'Content-Type'  = 'application/json'
}

$BaseHost = $BaseUrl -replace '^https?://', ''

# ---------------------------------------------------------------------------
# Helper: fetch all repos in the organisation (paged)
# ---------------------------------------------------------------------------
function Get-GiteaOrgRepositories {
    param([string]$OrgName)

    $Repos = @()
    $Page = 1
    $Limit = 50

    while ($true) {
        Write-Verbose "Fetching repository page $Page..."

        $Url = "$ApiUrl/orgs/$OrgName/repos?page=$Page&limit=$Limit"

        try {
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                $Response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get -SkipCertificateCheck:$SkipCertificateCheck
            }
            else {
                $Response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get
            }
        }
        catch {
            Write-Error "Failed to fetch repositories on page $Page : $_"

            return $null
        }

        if ($null -eq $Response) { break }
        if ($Response -isnot [Array]) { $Response = @($Response) }
        if ($Response.Count -eq 0) { break }

        # Filter out any archived repositories, as we don't want to modify those
        $Active = $Response | Where-Object { -not $_.archived }
        $Repos += $Active

        Write-Verbose "Page $Page : $($Response.Count) total, $($Active.Count) active — running total $($Repos.Count)"

        if ($Response.Count -lt $Limit) { break }
        $Page++
    }

    return $Repos
}

# ---------------------------------------------------------------------------
# Helper: fetch topics for a single repo
# ---------------------------------------------------------------------------
function Get-RepositoryTopics {
    param([string]$RepoName)

    $Url = "$ApiUrl/repos/$Organization/$RepoName/topics"

    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $Response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get -SkipCertificateCheck:$SkipCertificateCheck
        }
        else {
            $Response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get
        }

        return $Response.topics
    }
    catch {
        Write-Verbose "Could not fetch topics for ${RepoName}: $_"

        return @()
    }
}

# ---------------------------------------------------------------------------
# Helper: clone or update a repo locally
# ---------------------------------------------------------------------------
function Sync-Repository {
    param(
        [string]$RepoName,
        [string]$DestFolder
    )

    $CloneUrl = "https://oauth2:$Token@$BaseHost/$Organization/$RepoName.git"

    if (Test-Path (Join-Path $DestFolder '.git')) {
        Write-Verbose "  Pulling latest changes for $RepoName..."

        $output = git -C $DestFolder fetch origin main 2>&1
        $output = git -C $DestFolder reset --hard origin/main 2>&1

        return $LASTEXITCODE -eq 0
    }
    else {
        Write-Verbose "  Cloning $RepoName..."

        $null = New-Item -ItemType Directory -Path $DestFolder -Force
        $output = git clone --branch main --single-branch $CloneUrl $DestFolder 2>&1

        return $LASTEXITCODE -eq 0
    }
}

# ---------------------------------------------------------------------------
# Helper: determine an app-type label from repo topics
# ---------------------------------------------------------------------------
function Get-AppType {
    param([string[]]$Topics)

    $map = [ordered]@{
        'api'     = @('api', 'rest', 'restapi', 'webapi', 'graphql', 'microservice')
        'web'     = @('web', 'webapp', 'website', 'asp.net', 'aspnet', 'blazor', 'mvc', 'razor')
        'service' = @('service', 'windows-service', 'daemon', 'worker', 'background')
        'desktop' = @('desktop', 'winforms', 'wpf', 'winui', 'electron', 'windows')
        'android' = @('android', 'mobile', 'xamarin', 'maui')
        'library' = @('class-library', 'library', 'nuget', 'package', 'sdk', 'dll')
        'console' = @('console', 'cli', 'commandline', 'tool')
    }

    $lowerTopics = $Topics | ForEach-Object { $_.ToLower() }

    foreach ($type in $map.Keys) {
        foreach ($keyword in $map[$type]) {
            if ($lowerTopics -contains $keyword) { return $type }
        }
    }

    return 'application'
}

# ---------------------------------------------------------------------------
# Helper: build the deployment-process section hint for the prompt
# ---------------------------------------------------------------------------
function Get-DeploymentHint {
    param([string]$AppType)

    switch ($AppType) {
        'web' { return "a web application (e.g. IIS hosting/Kestral, publish profile, app-pool recycling)" }
        'api' { return "a REST/Web API (e.g. IIS hosting/Kestral, publish profile, app-pool recycling, Swagger endpoint)" }
        'service' { return "a Windows service or background worker (e.g. sc.exe install, service account, container deployment)" }
        'desktop' { return "a desktop/Windows application (e.g. ClickOnce, MSI/MSIX installer, SCCM/Intune deployment, shortcut creation)" }
        'android' { return "an Android / mobile application (e.g. APK signing, MDM distribution, Play Store / internal track)" }
        'library' { return "a NuGet package or shared library (e.g. pack, push to internal NuGet feed in Gitea, version tagging)" }
        'console' { return "a console / CLI tool (e.g. publish as self-contained executable, push to internal Releases area of repo in Gitea)" }
        default { return "the application (describe the deployment method relevant to this project)" }
    }
}

# ---------------------------------------------------------------------------
# Helper: remove a topic from a repository
# ---------------------------------------------------------------------------
function Remove-RepositoryTopic {
    param(
        [string]$RepoName,
        [string]$Topic
    )

    Write-Verbose "Removing topic '$Topic' from repository '$RepoName'..."

    if ($WhatIfPreference) {
        Write-Host "Would remove topic '$Topic' from repository '$RepoName'" -ForegroundColor Cyan
    }
    else {
        $Url = "$ApiUrl/repos/$Organization/$RepoName/topics/$Topic"

        try {
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                $Response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Delete -SkipCertificateCheck:$SkipCertificateCheck
            }
            else {
                $Response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Delete
            }

            Write-Verbose "Removed topic '$Topic' from '$RepoName'"
        }
        catch {
            Write-Warning "Failed to remove topic '$Topic' from '$RepoName': $_"
        }
    }
}

# ---------------------------------------------------------------------------
# Helper: invoke gh copilot agent to edit README.md directly in the repo
#   Returns $true on success, $false on failure
# ---------------------------------------------------------------------------
function Invoke-CopilotEditReadme {
    param(
        [string]$RepoName,
        [string]$RepoFolder,
        [string]$Description,
        [string]$AppType,
        [string]$DeploymentHint,
        [string[]]$Topics
    )

    $topicsLine = if ($Topics.Count -gt 0) { "Repository topics: $($Topics -join ', ')" } else { "No topics set." }
    $descriptionLine = if (-not [string]::IsNullOrWhiteSpace($Description)) { "Repository description (written by a human): $Description" } else { '' }

    $prompt = @"
You are a technical writer. Edit README.md in this repository to be a professional, accurate README.
$descriptionLine
$topicsLine
This is $DeploymentHint.

CRITICAL INSTRUCTION — ONLY MODIFY THE README.md file. Any modifications to other files is an error.

CRITICAL INSTRUCTION — HEADING NAMES ARE FIXED AND MUST NOT BE CHANGED UNDER ANY CIRCUMSTANCES.
Copy these heading lines into the file character-for-character. Any deviation is an error.

# $RepoName
## Overview
## System Owner and System Manager
## Installation
## Deployment Process
## Troubleshooting

Do not reword, rephrase, reorder, add, or remove any heading. The heading '## System Owner and System Manager' must appear with that exact text — not 'System Owners', not 'Ownership', not 'System Contacts', not 'Contacts', not anything else.

Rules:
- Scan the repository source files to write accurate, specific content for this project.
- Under '## Deployment Process' write instructions specifically for $AppType.
- Under '## System Owner and System Manager': if the section already exists with real names, preserve the entire section exactly as-is, word for word. Otherwise write:
| Name                | Email                                 | Responsibility   |
|---------------------|---------------------------------------|------------------|
| TBC   | TBC  | System Owner     |
| TBC   | TBC  | System Manager   |
- Only edit README.md. Do not modify any other file.
- Write only valid Markdown. No code fences around the whole document.
"@

    Write-Verbose "  Invoking gh copilot agent for $RepoName (model: $Model)..."

    try {
        Push-Location $RepoFolder

        try {
            # Let copilot have access to all tools except shell access to git commands, 
            # to prevent accidental modifications to files other than README.md or commits directly from the agent 
            # without human review
            $output = gh copilot --model $Model --allow-all-tools --deny-tool 'shell(git*)' -p $prompt -s 2>&1
        }
        finally {
            Pop-Location
        }

        Write-Host "  --- gh copilot output (exit code: $LASTEXITCODE) ---" -ForegroundColor DarkCyan

        # The output may contain important information about what the agent did, or errors it encountered, 
        # so we log it verbatim for troubleshooting purposes
        $output | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkCyan }
        
        Write-Host "  --- end gh copilot output ---" -ForegroundColor DarkCyan

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  gh copilot exited with code $LASTEXITCODE for $RepoName"
            
            return $false
        }

        return $true
    }
    catch {
        Write-Warning "  gh copilot invocation failed for ${RepoName}: $_"

        return $false
    }
}

# ===========================================================================
# MAIN
# ===========================================================================

Write-Host "`nGitea Organization GenAI README Generator" -ForegroundColor Cyan
Write-Host "Server      : $BaseUrl"       -ForegroundColor Gray
Write-Host "Organisation: $Organization"  -ForegroundColor Gray
Write-Host "Local path  : $LocalPath"     -ForegroundColor Gray
Write-Host "Model       : $Model"         -ForegroundColor Gray
Write-Host "Mode        : $(if ($WhatIfPreference) { 'Preview (WhatIf)' } else { 'Execute' })" `
    -ForegroundColor $(if ($WhatIfPreference) { 'Yellow' } else { 'Green' })
Write-Host ""

if ($WhatIfPreference) {
    Write-Host "WARNING: Running in preview mode - no files will be written or pushed" -ForegroundColor Yellow
    Write-Host ""
}

if (-not (Test-Path $LocalPath)) {
    $null = New-Item -ItemType Directory -Path $LocalPath -Force
    Write-Verbose "Created local folder: $LocalPath"
}

Write-Host "Fetching repositories from Gitea..." -ForegroundColor Yellow
$Repositories = Get-GiteaOrgRepositories -OrgName $Organization

if ($null -eq $Repositories -or $Repositories.Count -eq 0) {
    Write-Error "No repositories found or failed to fetch repositories."
    exit 1
}

Write-Host "Found $($Repositories.Count) active repositories`n" -ForegroundColor Green

# Disable git terminal prompts globally for this script, 
# to prevent any hanging if git commands encounter authentication issues or other problems
$env:GIT_TERMINAL_PROMPT = '0'

$Results = @()
$UpdatedCount = 0
$FailedCount = 0
$SkippedCount = 0

foreach ($Repo in $Repositories) {
    $RepoName = $Repo.name
    $topics = Get-RepositoryTopics -RepoName $RepoName
    $RepoFolder = Join-Path $LocalPath $RepoName

    Write-Host "Processing: $RepoName" -ForegroundColor White

    if ($Repo.empty) {
        Write-Host "  Skipping — repository is empty" -ForegroundColor Gray
        
        $SkippedCount++
        $Results += [PSCustomObject]@{ Repository = $RepoName; Status = 'Skipped - Empty'; AppType = ''; URL = $Repo.html_url }
        
        continue
    }

    If ($topics -notcontains "needs-readme") {
        Write-Host "  Skipping — repository does not have topic 'needs-readme'" -ForegroundColor Gray
        
        $SkippedCount++
        $Results += [PSCustomObject]@{ Repository = $RepoName; Status = 'Skipped - No Topic Flag'; AppType = ''; URL = $Repo.html_url }
        
        continue
    }

    # -----------------------------------------------------------------------
    # 1. Clone / pull
    # -----------------------------------------------------------------------
    $syncOk = Sync-Repository -RepoName $RepoName -DestFolder $RepoFolder

    if (-not $syncOk) {
        Write-Warning "  Failed to clone/pull $RepoName — skipping"
        
        $FailedCount++
        $Results += [PSCustomObject]@{ Repository = $RepoName; Status = 'Failed - Clone/Pull error'; AppType = ''; URL = $Repo.html_url }
        
        continue
    }

    # -----------------------------------------------------------------------
    # 2. Determine app type from topics
    # -----------------------------------------------------------------------
    $appType = Get-AppType -Topics $topics
    $deployHint = Get-DeploymentHint -AppType $appType

    Write-Host "  App type : $appType $(if ($topics.Count -gt 0) { "[$($topics -join ', ')]" })" -ForegroundColor DarkGray

    # -----------------------------------------------------------------------
    # 3. Let gh copilot agent edit README.md directly (WhatIf: skip this step)
    # -----------------------------------------------------------------------
    if ($WhatIfPreference) {
        Write-Host "  [WhatIf] Would invoke gh copilot to edit README.md, then commit and push" -ForegroundColor Yellow
        
        $UpdatedCount++
        $Results += [PSCustomObject]@{ Repository = $RepoName; Status = 'Would Update (WhatIf)'; AppType = $appType; URL = $Repo.html_url }
        
        continue
    }

    # Invoke the gh copilot agent to edit the README.md file directly in the repository folder, 
    # with a prompt that instructs it to only modify the README and not touch any other files.
    $copilotOk = Invoke-CopilotEditReadme `
        -RepoName       $RepoName `
        -RepoFolder     $RepoFolder `
        -Description    $($Repo.description) `
        -AppType        $appType `
        -DeploymentHint $deployHint `
        -Topics         $topics

    if (-not $copilotOk) {
        $FailedCount++
        $Results += [PSCustomObject]@{ Repository = $RepoName; Status = 'Failed - Copilot error'; AppType = $appType; URL = $Repo.html_url }
        
        continue
    }

    # -----------------------------------------------------------------------
    # 4. Safety check — ensure only README.md was modified
    # -----------------------------------------------------------------------
    $changedFiles = git -C $RepoFolder diff --name-only 2>&1
    $unexpectedChanges = $changedFiles | Where-Object { $_ -ne '' -and $_ -notmatch '^README\.md$' }

    if ($unexpectedChanges) {
        Write-Warning "  Copilot modified unexpected files — resetting and skipping:"

        $unexpectedChanges | ForEach-Object { Write-Warning "    $_" }
        git -C $RepoFolder checkout -- . 2>&1 | Out-Null
        $FailedCount++
        $Results += [PSCustomObject]@{ Repository = $RepoName; Status = 'Failed - Unexpected file changes'; AppType = $appType; URL = $Repo.html_url }
        
        continue
    }

    if (-not $DontPushToGit) {
        # -----------------------------------------------------------------------
        # 5. Commit and push
        # -----------------------------------------------------------------------
        $readmePath = Join-Path $RepoFolder 'README.md'
        git -C $RepoFolder add $readmePath 2>&1 | Out-Null

        $diffResult = git -C $RepoFolder diff --staged --quiet 2>&1
        $hasChanges = $LASTEXITCODE -ne 0

        if ($hasChanges) {
            git -C $RepoFolder commit -m "docs: AI-generated README [github-copilot]" 2>&1 | Out-Null

            Write-Verbose "  Pushing to origin/main..."
            $pushOutput = git -C $RepoFolder push origin main 2>&1

            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Pushed to main" -ForegroundColor Green
                
                $UpdatedCount++
                $Status = 'Updated'

                # Remove the topic flag regardless of push success, to prevent infinite retries on repos where the README is already good but the topic was never removed
                Remove-RepositoryTopic -RepoName $RepoName -Topic "needs-readme"
            }
            else {
                Write-Warning "  Push failed for $RepoName : $pushOutput"
                
                $FailedCount++
                $Status = 'Failed - Push error'
            }
        }
        else {
            Write-Host "  No changes detected — README already up to date" -ForegroundColor Gray
            
            $SkippedCount++
            $Status = 'Skipped - No changes'

            # Remove the topic flag regardless of push success, to prevent infinite retries on repos where the README is already good but the topic was never removed
            Remove-RepositoryTopic -RepoName $RepoName -Topic "needs-readme"
        }
    }
    else {
        Write-Host "  [DontPushToGit] Skipping commit and push steps" -ForegroundColor Yellow
        
        $UpdatedCount++
        $Status = 'Updated (Not Pushed - DontPushToGit)'
    }

    $Results += [PSCustomObject]@{ Repository = $RepoName; Status = $Status; AppType = $appType; URL = $Repo.html_url }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "  Repositories analysed : $($Repositories.Count)"  -ForegroundColor White
Write-Host "  READMEs updated       : $UpdatedCount"            -ForegroundColor $(if ($UpdatedCount -gt 0) { 'Green' } else { 'Gray' })
Write-Host "  Failed                : $FailedCount"             -ForegroundColor $(if ($FailedCount -gt 0) { 'Red' } else { 'Gray' })
Write-Host "  Skipped               : $SkippedCount"            -ForegroundColor Gray
Write-Host ""

if ($Results.Count -gt 0) {
    $Results | Format-Table -AutoSize
}

if ($WhatIfPreference -and $UpdatedCount -gt 0) {
    Write-Host "This was a preview run. Re-run without -WhatIf to apply changes." -ForegroundColor Yellow
}

Write-Host ""