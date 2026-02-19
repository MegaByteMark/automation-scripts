<#
.SYNOPSIS
    Gitea Organization GenAI Preparation Tool
    
.DESCRIPTION
    Adds the "needs-readme" topic to any repositories in the specified Gitea organization that do not appear on the exceptions 
    list of repositories that should be ignored by this script, which can be modified within the script itself.

    See the script "gitea_org_genai_readme.ps1" for the companion script that generates README files for repositories tagged with "needs-readme".
    
.PARAMETER BaseUrl
    Gitea server base URL
    
.PARAMETER Organization
    Organization name
    
.PARAMETER Token
    Gitea personal access token (required)
    
.PARAMETER SkipCertificateCheck
    Skip SSL certificate validation (for self-signed certificates)
    
.PARAMETER WhatIf
    Preview changes without actually making them
    
.EXAMPLE
    .\gitea_prep_org_for_genai.ps1 -BaseUrl "https://your_gitea_server" -Organization "your_organization" -Token "your_token" -SkipCertificateCheck -WhatIf
    
.EXAMPLE
    .\gitea_prep_org_for_genai.ps1 -BaseUrl "https://your_gitea_server" -Organization "your_organization" -Token "your_token" -SkipCertificateCheck
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
    [switch]$SkipCertificateCheck
)

# Skip certificate validation if requested (for self-signed certs)
if ($SkipCertificateCheck) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        # PowerShell Core
        $PSDefaultParameterValues['Invoke-RestMethod:SkipCertificateCheck'] = $true
        $PSDefaultParameterValues['Invoke-WebRequest:SkipCertificateCheck'] = $true
    }
    else {
        # Windows PowerShell
        add-type @"
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

# API Configuration
$ApiUrl = "$($BaseUrl.TrimEnd('/'))/api/v1"
$Headers = @{
    'Authorization' = "token $Token"
    'Content-Type'  = 'application/json'
}

$ExceptionList = @(
    "LVSystem",
    "PASManager",
    "PAAFTAF"
)

function Get-GiteaOrgRepositories {
    param(
        [string]$OrgName
    )
    
    $Repos = @()
    $Page = 1
    $Limit = 50
    $ContinueFetching = $true
    
    while ($ContinueFetching) {
        Write-Verbose "Fetching page $Page of repositories..."
        
        $Url = "$ApiUrl/orgs/$OrgName/repos?page=$Page&limit=$Limit"
        
        try {
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                $Response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get -SkipCertificateCheck:$SkipCertificateCheck
            }
            else {
                $Response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get
            }
            
            # Handle both array and single object responses
            if ($Response -is [Array]) {
                $RepoCount = $Response.Count
            }
            elseif ($null -ne $Response) {
                $RepoCount = 1
                $Response = @($Response)
            }
            else {
                $RepoCount = 0
            }
            
            # If no results, we're done
            if ($RepoCount -eq 0) {
                Write-Verbose "No more repositories found."
                
                $ContinueFetching = $false
                
                break
            }
            
            # Filter out archived repositories
            $ActiveRepos = $Response | Where-Object { -not $_.archived -and -not $ExceptionList.Contains($_.name)  }
            $Repos += $ActiveRepos
            $ArchivedCount = $RepoCount - $ActiveRepos.Count
            
            Write-Verbose "Page $Page : $RepoCount total ($($ActiveRepos.Count) active, $ArchivedCount archived) - Running total: $($Repos.Count) active repos"
            
            # If we got fewer results than the limit, this is the last page
            if ($RepoCount -lt $Limit) {
                $ContinueFetching = $false
            }
            
            $Page++
        }
        catch {
            Write-Error "Failed to fetch repositories on page $Page : $_"
            Write-Error $_.Exception.Message
            
            return $null
        }
    }
    
    Write-Verbose "Finished fetching all repositories. Total active: $($Repos.Count)"
    
    return $Repos
}

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

        return @($Response.topics)
    }
    catch {
        Write-Verbose "Could not fetch topics for ${RepoName}: $_"

        return @()
    }
}

function Gitea-AddReadmeTag {
    param(
        [Parameter(Mandatory = $true)]
        $Repo,
        [string[]]$CachedTopics = $null
    )
    
    $RepoName = $Repo.name
    $CurrentTopics = if ($null -ne $CachedTopics) { $CachedTopics } else { Get-RepositoryTopics -RepoName $RepoName }

    if ($CurrentTopics -contains "needs-readme") {
        Write-Verbose "Repository '$RepoName' already has 'needs-readme' tag, skipping."

        return
    }

    $NewTopics = $CurrentTopics + "needs-readme"

    Set-RepositoryTopics -RepoName $RepoName -Topics $NewTopics
}

function Set-RepositoryTopics {
    param(
        [string]$RepoName,
        [array]$Topics
    )
    
    $Url = "$ApiUrl/repos/$Organization/$RepoName/topics"
    
    $Body = @{
        topics = $Topics
    } | ConvertTo-Json
    
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $Response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Put -Body $Body -SkipCertificateCheck:$SkipCertificateCheck
        }
        else {
            $Response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Put -Body $Body
        }

        return $true
    }
    catch {
        Write-Warning "Failed to set topics for $RepoName : $_"

        return $false
    }
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------
Write-Host "`nGitea Organization GenAI Preparation Tool" -ForegroundColor Cyan
Write-Host "Server      : $BaseUrl"       -ForegroundColor Gray
Write-Host "Organisation: $Organization"  -ForegroundColor Gray
Write-Host "Mode        : $(if ($WhatIfPreference) { 'Preview (WhatIf)' } else { 'Execute' })" `
    -ForegroundColor $(if ($WhatIfPreference) { 'Yellow' } else { 'Green' })
Write-Host ""

# Get repos from Gitea, filtered only to active repos that are not in the exception list
$Repositories = Get-GiteaOrgRepositories -OrgName $Organization

# ---------------------------------------------------------------------------
# Always export a timestamped CSV backup of current topics before any topic changes
# ---------------------------------------------------------------------------
$BackupPath = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "topics_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

Write-Host "Exporting topics backup to $BackupPath..." -ForegroundColor Yellow

$TopicsCache = @{}
$BackupData = @()

foreach ($Repo in $Repositories) {
    $topics = Get-RepositoryTopics -RepoName $Repo.name
    $TopicsCache[$Repo.name] = $topics

    $BackupData += [PSCustomObject]@{
        Repository = $Repo.name
        Topics     = $topics -join ','
    }
}

try {
    $BackupData | Export-Csv -Path $BackupPath -NoTypeInformation -ErrorAction Stop -WhatIf:$false

    Write-Host "Backup saved to: $BackupPath ($($BackupData.Count) repositories)" -ForegroundColor Green
}
catch {
    Write-Warning "Failed to save backup CSV: $_"
    Write-Warning "Aborting to prevent data loss — fix the backup path and retry."

    exit 1
}

foreach ($Repo in $Repositories) {
    $RepoName = $Repo.name
    $CurrentTopics = $TopicsCache[$RepoName]

    if ($CurrentTopics -contains "needs-readme") {
        Write-Host "Repository '$RepoName' already has 'needs-readme' tag, skipping."

        continue
    }

    Write-Host "Tagging repository '$RepoName' with 'needs-readme'..."

    # Adding topic to repository 
    If ($WhatIfPreference) {
        Write-Host "Would add 'needs-readme' tag to repository '$RepoName'" -ForegroundColor Cyan
    }
    else {
        Gitea-AddReadmeTag -Repo $Repo -CachedTopics $CurrentTopics
    }
}