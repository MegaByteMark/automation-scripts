<#
.SYNOPSIS
    Gitea Repository Branch Analyzer
    
.DESCRIPTION
    Lists all repositories in a Gitea organization that have branches other than
    the standard main/master and develop branches.
    This script is useful for identifying repositories that may have non-standard branching strategies or legacy branches that should be reviewed.
    or branches that have been left behind after development work has been completed.
    
.PARAMETER BaseUrl
    Gitea server base URL
    
.PARAMETER Organization
    Organization name
    
.PARAMETER Token
    Gitea personal access token (required)
    
.PARAMETER SkipCertificateCheck
    Skip SSL certificate validation (for self-signed certificates)
    Useful if you are running this script in an on-premises environment with a self-signed certificate. Use with caution.
    
.PARAMETER ExportCsv
    Export results to CSV file
    
.EXAMPLE
    .\gitea_branch_analyzer.ps1 -BaseUrl "https://yoururl.gitea.com" -Organization "your_organization" -Token "your_token" -SkipCertificateCheck
    
.EXAMPLE
    .\gitea_branch_analyzer.ps1 -BaseUrl "https://yoururl.gitea.com" -Organization "your_organization" -Token "your_token" -SkipCertificateCheck -ExportCsv
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,
    
    [Parameter(Mandatory = $true)]
    [string]$Organization,
    
    [Parameter(Mandatory = $true)]
    [string]$Token,
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipCertificateCheck,
    
    [Parameter(Mandatory = $false)]
    [switch]$ExportCsv
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

# Standard branches to exclude
$StandardBranches = @('main', 'master', 'develop')

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
            $ActiveRepos = $Response | Where-Object { -not $_.archived }
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

function Get-RepositoryBranches {
    param(
        [string]$RepoName
    )
    
    $Branches = @()
    $Page = 1
    $Limit = 50
    $ContinueFetching = $true
    
    while ($ContinueFetching) {
        $Url = "$ApiUrl/repos/$Organization/$RepoName/branches?page=$Page&limit=$Limit"
        
        try {
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                $Response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get -SkipCertificateCheck:$SkipCertificateCheck
            }
            else {
                $Response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get
            }
            
            # Handle both array and single object responses
            if ($Response -is [Array]) {
                $BranchCount = $Response.Count
            }
            elseif ($null -ne $Response) {
                $BranchCount = 1
                $Response = @($Response)
            }
            else {
                $BranchCount = 0
            }
            
            if ($BranchCount -eq 0) {
                $ContinueFetching = $false
                break
            }
            
            $Branches += $Response
            
            if ($BranchCount -lt $Limit) {
                $ContinueFetching = $false
            }
            
            $Page++
        }
        catch {
            Write-Verbose "Failed to fetch branches for $RepoName : $_"
            return @()
        }
    }
    
    return $Branches
}

# Main Script
Write-Host "`nGitea Repository Branch Analyzer" -ForegroundColor Cyan
Write-Host "Server: $BaseUrl" -ForegroundColor Gray
Write-Host "Organization: $Organization" -ForegroundColor Gray
Write-Host "Standard branches (excluded): $($StandardBranches -join ', ')" -ForegroundColor Gray
Write-Host ""

# Fetch all repositories
Write-Host "Fetching repositories..." -ForegroundColor Yellow
$Repositories = Get-GiteaOrgRepositories -OrgName $Organization

if ($null -eq $Repositories -or $Repositories.Count -eq 0) {
    Write-Error "No repositories found or failed to fetch repositories"
    exit 1
}

Write-Host "Found $($Repositories.Count) repositories`n" -ForegroundColor Green

$Results = @()
$ReposWithNonStandardBranches = 0

foreach ($Repo in $Repositories) {
    $RepoName = $Repo.name
    
    Write-Host "Analyzing: $RepoName" -ForegroundColor White
    
    # Check if repository is empty
    if ($Repo.empty) {
        Write-Host "  ⚠️  Repository is empty (skipping)" -ForegroundColor Gray
        continue
    }
    
    # Get all branches
    $Branches = Get-RepositoryBranches -RepoName $RepoName
    
    if ($null -eq $Branches -or $Branches.Count -eq 0) {
        Write-Host "  ℹ️  No branches found" -ForegroundColor Gray
        continue
    }
    
    # Filter out standard branches
    $NonStandardBranches = $Branches | Where-Object { 
        $_.name -notin $StandardBranches 
    }
    
    if ($NonStandardBranches.Count -gt 0) {
        $ReposWithNonStandardBranches++
        
        Write-Host "  🔍 Found $($NonStandardBranches.Count) non-standard branch(es):" -ForegroundColor Yellow
        
        foreach ($Branch in $NonStandardBranches) {
            Write-Host "     - $($Branch.name)" -ForegroundColor Cyan
            
            $Results += [PSCustomObject]@{
                Repository   = $RepoName
                BranchName   = $Branch.name
                LastCommit   = $Branch.commit.id.Substring(0, 7)
                CommitDate   = $Branch.commit.timestamp
                URL          = $Repo.html_url
            }
        }
    }
    else {
        Write-Host "  ✅ Only standard branches found ($($Branches.Count) total)" -ForegroundColor Green
    }
}

# Summary
Write-Host "`n" + ("=" * 80) -ForegroundColor Cyan
Write-Host "`nSummary:" -ForegroundColor Cyan
Write-Host "  Total repositories analyzed: $($Repositories.Count)" -ForegroundColor White
Write-Host "  Repositories with non-standard branches: $ReposWithNonStandardBranches" -ForegroundColor Yellow
Write-Host "  Total non-standard branches found: $($Results.Count)" -ForegroundColor Yellow

if ($Results.Count -gt 0) {
    Write-Host "`nDetailed Results:" -ForegroundColor Cyan
    $Results | Format-Table -AutoSize
    
    # Export to CSV if requested
    if ($ExportCsv) {
        $CsvPath = "gitea-branch-analysis-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
        $Results | Export-Csv -Path $CsvPath -NoTypeInformation
        Write-Host "`nResults exported to: $CsvPath" -ForegroundColor Green
    }
}
else {
    Write-Host "`n✅ All repositories only contain standard branches (main/master/develop)" -ForegroundColor Green
}

Write-Host ""