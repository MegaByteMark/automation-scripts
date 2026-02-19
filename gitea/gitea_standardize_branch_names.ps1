<#
.SYNOPSIS
    Gitea Branch Standardization Tool
    
.DESCRIPTION
    Renames 'master' branches to 'main' and standardizes branch names to lowercase
    (main, develop) across all repositories in a Gitea organization.
    
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
    
.PARAMETER ExportCsv
    Export results to CSV file
    
.EXAMPLE
    .\gitea_branch_standardize.ps1 -BaseUrl "https://yoururl.gitea.com" -Organization "your_organization" -Token "your_token" -SkipCertificateCheck -WhatIf
    
.EXAMPLE
    .\gitea_branch_standardize.ps1 -BaseUrl "https://yoururl.gitea.com" -Organization "your_organization" -Token "your_token" -SkipCertificateCheck
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

# Branch name mappings (old name -> new name)
# Branch names to standardize (check case-insensitively, rename to lowercase)
$StandardBranchNames = @{
    'master'  = 'main'
    'develop' = 'develop'
    'main'    = 'main'
}

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

function Get-RepositoryDefaultBranch {
    param(
        [string]$RepoName
    )
    
    $Url = "$ApiUrl/repos/$Organization/$RepoName"
    
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $Response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get -SkipCertificateCheck:$SkipCertificateCheck
        }
        else {
            $Response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get
        }
        
        return $Response.default_branch
    }
    catch {
        Write-Warning "Failed to get default branch for $RepoName : $_"
        
        return $null
    }
}

function Copy-GiteaBranch {
    param(
        [string]$RepoName,
        [string]$SourceBranch,
        [string]$NewBranchName
    )
    
    $Url = "$ApiUrl/repos/$Organization/$RepoName/branches"
    
    $Body = @{
        new_branch_name   = $NewBranchName
        old_branch_name   = $SourceBranch
    } | ConvertTo-Json
    
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $null = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Post -Body $Body -SkipCertificateCheck:$SkipCertificateCheck
        }
        else {
            $null = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Post -Body $Body
        }
        
        return $true
    }
    catch {
        Write-Warning "Failed to create branch '$NewBranchName' from '$SourceBranch': $_"
        
        return $false
    }
}

function Remove-GiteaBranch {
    param(
        [string]$RepoName,
        [string]$BranchName
    )
    
    $Url = "$ApiUrl/repos/$Organization/$RepoName/branches/$BranchName"
    
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $null = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Delete -SkipCertificateCheck:$SkipCertificateCheck
        }
        else {
            $null = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Delete
        }
        
        return $true
    }
    catch {
        Write-Warning "Failed to delete branch '$BranchName': $_"
        
        return $false
    }
}

function Set-RepositoryDefaultBranch {
    param(
        [string]$RepoName,
        [string]$BranchName
    )
    
    $Url = "$ApiUrl/repos/$Organization/$RepoName"
    
    $Body = @{
        default_branch = $BranchName
    } | ConvertTo-Json
    
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $Response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Patch -Body $Body -SkipCertificateCheck:$SkipCertificateCheck
        }
        else {
            $Response = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Patch -Body $Body
        }
        
        return $true
    }
    catch {
        Write-Warning "Failed to set default branch to '$BranchName' in $RepoName : $_"
        
        return $false
    }
}

# Main Script
Write-Host "`nGitea Branch Standardization Tool" -ForegroundColor Cyan
Write-Host "Server: $BaseUrl" -ForegroundColor Gray
Write-Host "Organization: $Organization" -ForegroundColor Gray
Write-Host "Mode: $(if ($WhatIfPreference) { 'Preview (WhatIf)' } else { 'Execute' })" -ForegroundColor $(if ($WhatIfPreference) { 'Yellow' } else { 'Green' })
Write-Host ""

if ($WhatIfPreference) {
    Write-Host "⚠️  Running in preview mode - no changes will be made" -ForegroundColor Yellow
    Write-Host ""
}

# Fetch all repositories
Write-Host "Fetching repositories..." -ForegroundColor Yellow

$Repositories = Get-GiteaOrgRepositories -OrgName $Organization

if ($null -eq $Repositories -or $Repositories.Count -eq 0) {
    Write-Error "No repositories found or failed to fetch repositories"
    
    exit 1
}

Write-Host "Found $($Repositories.Count) repositories`n" -ForegroundColor Green

$Results = @()
$RenamedCount = 0
$FailedCount = 0
$SkippedCount = 0

foreach ($Repo in $Repositories) {
    $RepoName = $Repo.name
    
    Write-Host "Analyzing: $RepoName" -ForegroundColor White
    
    # Check if repository is empty
    if ($Repo.empty) {
        Write-Host "  ⚠️  Repository is empty (skipping)" -ForegroundColor Gray
        
        $SkippedCount++
        
        continue
    }
    
    # Get all branches
    $Branches = Get-RepositoryBranches -RepoName $RepoName
    
    if ($null -eq $Branches -or $Branches.Count -eq 0) {
        Write-Host "  ℹ️  No branches found" -ForegroundColor Gray
        continue
    }
    
    # Get current default branch
    $DefaultBranch = Get-RepositoryDefaultBranch -RepoName $RepoName
    
    foreach ($Branch in $Branches) {
        $BranchName = $Branch.name
        $NewName = $null
        
        # Check if this branch needs to be renamed
        $LowerBranchName = $BranchName.ToLower()
        
        if ($StandardBranchNames.ContainsKey($LowerBranchName)) {
            $NewName = $StandardBranchNames[$LowerBranchName]
            
            # Only rename if the case is different or it's master->main
            if ($BranchName -ceq $NewName) {
                # Already correct (case-sensitive match)
                $NewName = $null
            }
        }
        
        if ($null -ne $NewName -and $NewName -ne $BranchName) {
            # Check if target branch already exists
            $TargetExists = $Branches | Where-Object { $_.name -eq $NewName }
            
            if ($TargetExists) {
                Write-Host "  ⚠️  Cannot rename '$BranchName' -> '$NewName' (target already exists)" -ForegroundColor Yellow
                
                $Results += [PSCustomObject]@{
                    Repository     = $RepoName
                    OldBranchName  = $BranchName
                    NewBranchName  = $NewName
                    WasDefault     = ($DefaultBranch -eq $BranchName)
                    Status         = "Skipped - Target Exists"
                    URL            = $Repo.html_url
                }

                $SkippedCount++

                continue
            }
            
            $IsDefault = ($DefaultBranch -eq $BranchName)
            
            Write-Host "  🔄 Renaming: '$BranchName' -> '$NewName'$(if ($IsDefault) { ' (default branch)' })" -ForegroundColor Cyan
            
            if (-not $WhatIfPreference) {
                # Step 1: Create new branch from old branch
                $CopySuccess = Copy-GiteaBranch -RepoName $RepoName -SourceBranch $BranchName -NewBranchName $NewName
                
                if ($CopySuccess) {
                    Write-Host "     ✅ Created branch '$NewName'" -ForegroundColor Green
                    
                    # Step 2: If this was the default branch, update it before deleting old
                    if ($IsDefault) {
                        $DefaultSuccess = Set-RepositoryDefaultBranch -RepoName $RepoName -BranchName $NewName
                        
                        if ($DefaultSuccess) {
                            Write-Host "     ✅ Default branch set to '$NewName'" -ForegroundColor Green
                        }
                        else {
                            Write-Host "     ❌ Failed to set default branch - aborting (old branch kept)" -ForegroundColor Red
                            
                            $FailedCount++
                            $Status = "Partial - Default not set"

                            $Results += [PSCustomObject]@{
                                Repository     = $RepoName
                                OldBranchName  = $BranchName
                                NewBranchName  = $NewName
                                WasDefault     = $IsDefault
                                Status         = $Status
                                URL            = $Repo.html_url
                            }

                            continue
                        }
                    }
                    
                    # Step 3: Delete old branch
                    $DeleteSuccess = Remove-GiteaBranch -RepoName $RepoName -BranchName $BranchName
                    
                    if ($DeleteSuccess) {
                        Write-Host "     ✅ Deleted old branch '$BranchName'" -ForegroundColor Green
                        $RenamedCount++
                        $Status = "Renamed"
                    }
                    else {
                        Write-Host "     ⚠️  Could not delete '$BranchName' (may be protected)" -ForegroundColor Yellow
                        $RenamedCount++
                        $Status = "Renamed (old branch remains)"
                    }
                }
                else {
                    Write-Host "     ❌ Failed to create new branch" -ForegroundColor Red
                    $FailedCount++
                    $Status = "Failed"
                }
            }
            else {
                $Status = "Would Rename (WhatIf)"
                $RenamedCount++
            }
            
            $Results += [PSCustomObject]@{
                Repository     = $RepoName
                OldBranchName  = $BranchName
                NewBranchName  = $NewName
                WasDefault     = $IsDefault
                Status         = $Status
                URL            = $Repo.html_url
            }
        }
    }
}

# Summary
Write-Host "`n" + ("=" * 80) -ForegroundColor Cyan
Write-Host "`nSummary:" -ForegroundColor Cyan
Write-Host "  Total repositories analyzed: $($Repositories.Count)" -ForegroundColor White
Write-Host "  Branches renamed: $RenamedCount" -ForegroundColor $(if ($RenamedCount -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Branches failed: $FailedCount" -ForegroundColor $(if ($FailedCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Branches skipped: $SkippedCount" -ForegroundColor Gray

if ($Results.Count -gt 0) {
    Write-Host "`nDetailed Results:" -ForegroundColor Cyan
    $Results | Format-Table -AutoSize
    
    # Export to CSV if requested
    if ($ExportCsv) {
        $CsvPath = "gitea-branch-standardization-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
        $Results | Export-Csv -Path $CsvPath -NoTypeInformation
        Write-Host "`nResults exported to: $CsvPath" -ForegroundColor Green
    }
}
else {
    Write-Host "`n✅ All branches are already standardized (main, develop in lowercase)" -ForegroundColor Green
}

if ($WhatIfPreference -and $RenamedCount -gt 0) {
    Write-Host "`n⚠️  This was a preview run. Re-run without -WhatIf to apply changes." -ForegroundColor Yellow
}

Write-Host ""