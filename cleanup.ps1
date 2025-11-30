<#
.SYNOPSIS
    Comprehensive Azure resource group cleanup script with intelligent dependency handling.

.DESCRIPTION
    This script performs intelligent cleanup of Azure resource groups by identifying and deleting those not
    tagged with keep=true. It automatically handles complex dependencies that commonly block deletion:
    
    Cleanup Operations (in order):
    1. Azure NetApp Files resources (volumes, pools, accounts)
    2. Network resources (VNets, NSGs, NICs, Gateways, Peerings)
    3. Data Collection Rule (DCR) associations
    4. Recovery Services vaults with backup items
    5. Resource locks
    6. Final resource group deletion
    
    The script supports multiple cleanup modes for targeted operations and both synchronous and asynchronous
    execution for optimal performance.

.PARAMETER Async
    Execute resource group deletions asynchronously in background jobs for parallel processing.
    Default is synchronous (blocking) deletion.

.PARAMETER RemoveLocks
    Automatically remove any resource locks before deletion.
    Default behavior is to only report locks without removing them.

.PARAMETER CleanupMode
    Specifies the cleanup operation mode:
    - Full: Complete cleanup with all dependency removals and RG deletion (default)
    - DCROnly: Remove only Data Collection Rule associations
    - VaultOnly: Clean up only Recovery Services vaults
    - NetAppOnly: Clean up only Azure NetApp Files resources
    - OrderedFull: Full cleanup with enhanced dependency ordering

.PARAMETER ResourceGroupName
    Target a specific resource group instead of processing all untagged groups.
    Useful for testing or targeted cleanup operations.

.PARAMETER RemoveVaults
    Clean up Recovery Services vaults before deleting resource groups (default: $true).
    Handles backup items, protected resources, and vault dependencies.

.PARAMETER RemoveNetApp
    Clean up Azure NetApp Files resources before deleting resource groups (default: $true).
    Handles volumes, capacity pools, and NetApp accounts with proper ordering.

.PARAMETER RemoveNetworkDependencies
    Remove network dependencies that might block deletion (default: $true).
    Includes VNets, subnets, NSGs, NICs, gateways, peerings, and associated resources.

.PARAMETER RemoveDcrAssociations
    Remove Data Collection Rule associations before deletion (default: $true).
    Handles cross-resource-group DCR dependencies.

.PARAMETER UseCLI
    Use Azure CLI for DCR association removal (default: $true).
    More reliable than REST API for DCR operations.

.PARAMETER UseRESTAPI
    Use REST API for DCR association removal if CLI fails (default: $false).
    Fallback method when CLI is unavailable.

.PARAMETER UpdateAzExtensions
    Update Azure CLI extensions before running cleanup.
    Helps resolve extension-related warnings and errors.

.PARAMETER FixProblematicExtensions
    Reinstall known problematic extensions (e.g., containerapp).
    Fixes extension import errors and compatibility issues.

.EXAMPLE
    .\cleanup.ps1
    
    Basic usage - deletes all resource groups not tagged with keep=true, handling all dependencies.

.EXAMPLE
    .\cleanup.ps1 -ResourceGroupName "my-test-rg"
    
    Clean up a specific resource group with full dependency handling.

.EXAMPLE
    .\cleanup.ps1 -Async -RemoveLocks
    
    Delete all untagged resource groups asynchronously, removing locks in parallel.

.EXAMPLE
    .\cleanup.ps1 -ResourceGroupName "my-rg" -CleanupMode "NetAppOnly"
    
    Only clean up Azure NetApp Files resources without deleting the resource group.

.EXAMPLE
    .\cleanup.ps1 -ResourceGroupName "my-rg" -CleanupMode "VaultOnly"
    
    Only clean up Recovery Services vaults without deleting the resource group.


.EXAMPLE
    .\cleanup.ps1 -ResourceGroupName "my-rg" -CleanupMode "VaultOnly"
    
    Only clean up Recovery Services vaults without deleting the resource group.

.EXAMPLE
    .\cleanup.ps1 -ResourceGroupName "my-rg" -CleanupMode "DCROnly"
    
    Only remove Data Collection Rule associations without deleting the resource group.

.EXAMPLE
    .\cleanup.ps1 -ResourceGroupName "my-rg" -CleanupMode "OrderedFull" -RemoveNetworkDependencies
    
    Use ordered cleanup approach for complex dependencies including network resources.

.EXAMPLE
    .\cleanup.ps1 -UpdateAzExtensions
    
    Update Azure CLI extensions before cleanup to prevent extension warnings.

.EXAMPLE
    .\cleanup.ps1 -RemoveVaults:$false -RemoveNetApp:$false
    
    Delete resource groups without attempting vault or NetApp resource cleanup.

.NOTES
    Author: Azure Cleanup Script
    Version: 2.0
    Requires: Az.Network, Az.Resources, Az.RecoveryServices PowerShell modules
    
    Prerequisites:
    - Azure PowerShell modules installed
    - Authenticated to Azure (Connect-AzAccount)
    - Appropriate permissions (Contributor or Owner role)
    
    Related Scripts:
    - cleanup_network.ps1: Network resource cleanup (VNets, NSGs, NICs)
    - cleanup_dcr.ps1: Data Collection Rule association removal
    - cleanup_vault.ps1: Recovery Services vault cleanup
    - cleanup_netapp_resources.ps1: Azure NetApp Files cleanup
    - Update-AzureCliExtensions.ps1: Azure CLI extension management
    
    Operation Flow:
    1. Connect to Azure and verify subscription context
    2. Categorize resource groups by 'keep=true' tag
    3. Display summary of resources to be deleted
    4. For each untagged resource group:
       a. Clean up NetApp resources (volumes → pools → accounts)
       b. Clean up network dependencies (NICs → VNets → NSGs → Gateways)
       c. Remove DCR associations
       d. Clean up Recovery Services vaults
       e. Remove resource locks
       f. Delete resource group
    5. Monitor progress (async) or wait for completion (sync)
    
    Tag Convention:
    - Resource groups tagged with 'keep=true' are protected from deletion
    - All other resource groups are considered candidates for deletion
    
    Warning: This script permanently deletes Azure resources and resource groups.
    Always verify the operation in a test environment before running in production.
#>

#>

# Script parameters
param (
    [Parameter(Mandatory = $false)]
    [switch]$Async = $false,
    
    [Parameter(Mandatory = $false)]
    [switch]$RemoveLocks = $false,
    
    [Parameter(Mandatory = $false)]
    [switch]$RemoveDcrAssociations = $true,
    
    [Parameter(Mandatory = $false)]
    [switch]$UseCLI = $true,
    
    [Parameter(Mandatory = $false)]
    [switch]$UseRESTAPI = $false,
    
    [Parameter(Mandatory = $false)]
    [switch]$UpdateAzExtensions = $false,
    
    [Parameter(Mandatory = $false)]
    [switch]$FixProblematicExtensions = $false,
    
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("Full", "DCROnly", "VaultOnly", "NetAppOnly", "OrderedFull")]
    [string]$CleanupMode = "Full",
    
    [Parameter(Mandatory = $false)]
    [switch]$RemoveVaults = $true,
    
    [Parameter(Mandatory = $false)]
    [switch]$RemoveNetApp = $true,
    
    [Parameter(Mandatory = $false)]
    [switch]$RemoveNetworkDependencies = $true
)

# Import external functions
. "$PSScriptRoot\Update-AzureCliExtensions.ps1"

function Remove-DataCollectionRuleAssociations {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $false)]
        [switch]$UseFallbackMethod = $false,
        
        [Parameter(Mandatory = $false)]
        [switch]$NoWaitOnDelete = $false
    )
    
    try {
        # Use external cleanup_dcr.ps1 script
        $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath "cleanup_dcr.ps1"
        
        if (Test-Path $scriptPath) {
            Write-Host "  Using external DCR cleanup script..." -ForegroundColor Yellow
            
            $params = @{
                ResourceGroupName = $ResourceGroupName
                Force             = $true
                PassThru          = $true
            }
            
            if ($NoWaitOnDelete) {
                $params.Add("NoWaitOnDelete", $true)
            }
            
            if ($UseFallbackMethod -or $UseRESTAPI) {
                $params.Add("UseRESTAPI", $true)
            }
            elseif ($UseCLI) {
                $params.Add("UseCLI", $true)
            }
            
            # Call the external script
            return & $scriptPath @params
        }
        else {
            Write-Error "Required script 'cleanup_dcr.ps1' not found at $scriptPath"
            Write-Host "  Please make sure the cleanup_dcr.ps1 script exists in the same directory." -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Error "Error removing Data Collection Rule associations: $_"
        Write-Host "  Consider using Azure Portal to manually remove these associations or use the -UseFallbackMethod option." -ForegroundColor Yellow
        return $false
    }
}

# Function to delete a resource group
function Remove-ResourceGroupSafely {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $false)]
        [switch]$Force,
        
        [Parameter(Mandatory = $false)]
        [switch]$Async = $false,
        
        [Parameter(Mandatory = $false)]
        [switch]$RemoveLocks = $false
    )
    
    process {
        try {
            # Check if the resource group exists
            $resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
            
            if ($null -eq $resourceGroup) {
                Write-Warning "Resource group '$ResourceGroupName' does not exist."
                return
            }
            
            # Check if the resource group has the 'keep' tag set to 'true'
            if ($resourceGroup.Tags -and $resourceGroup.Tags['keep'] -eq 'true') {
                Write-Warning "Resource group '$ResourceGroupName' is tagged with keep=true and will NOT be deleted."
                return
            }
            
            # Show deletion confirmation
            if ($Force -or $PSCmdlet.ShouldProcess($ResourceGroupName, "Delete resource group")) {
                Write-Host "Deleting resource group: $ResourceGroupName" -ForegroundColor Yellow

                # 1. First, check for NetApp resources and remove them if RemoveNetApp is true
                Write-Host "  [1/5] Checking for NetApp resources..." -ForegroundColor Yellow
                $netappScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "cleanup_netapp_resources.ps1"
                & $netappScriptPath -ResourceGroupName $ResourceGroupName -Force:$Force
               
                # 2. Second, check for network dependencies and remove them if RemoveNetworkDependencies is true
                Write-Host "  [2/5] Checking for network dependencies..." -ForegroundColor Yellow
                $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath "cleanup_network.ps1"
                & $scriptPath -ResourceGroupName $ResourceGroupName -Force -PassThru
           
                # 3. Remove any Data Collection Rule associations before attempting to delete if enabled
                Write-Host "  [3/5] Checking for Data Collection Rule associations..." -ForegroundColor Yellow
                $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath "cleanup_dcr.ps1"
                & $scriptPath -ResourceGroupName $ResourceGroupName -Force -PassThru
                
                # 4. Check for Recovery Services vaults and remove them if RemoveVaults is true
                if ((Get-Variable -Name RemoveVaults -Scope Script -ErrorAction SilentlyContinue) -and $RemoveVaults) {
                    Write-Host "  [4/5] Checking for Recovery Services vaults..." -ForegroundColor Yellow
                    $vaults = Get-RecoveryServicesVaultsInResourceGroup -ResourceGroupName $ResourceGroupName
                    
                    if ($vaults -and $vaults.Count -gt 0) {
                        Write-Host "  Found $($vaults.Count) Recovery Services vault(s). Cleaning up..." -ForegroundColor Yellow
                        
                        foreach ($vault in $vaults) {
                            Write-Host "  Processing vault: $($vault.Name)" -ForegroundColor Yellow
                            # Use external cleanup_vault.ps1 script
                            $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath "cleanup_vault.ps1"
                            if (Test-Path $scriptPath) {
                                $vaultRemoved = & $scriptPath -VaultName $vault.Name -ResourceGroup $ResourceGroupName -Force -PassThru
                            }
                            else {
                                Write-Error "Required script 'cleanup_vault.ps1' not found at $scriptPath"
                                $vaultRemoved = $false
                            }
                            
                            if (-not $vaultRemoved) {
                                Write-Warning "  Failed to completely remove vault $($vault.Name). Resource group deletion may fail."
                            }
                            else {
                                Write-Host "  Vault $($vault.Name) successfully removed." -ForegroundColor Green
                            }
                        }
                    }
                }
                
                
                # Check for resource locks and remove them if found
                Write-Host "  [5/5] Checking for resource locks..." -ForegroundColor Yellow
                $locks = Get-AzResourceLock -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
                if ($locks) {
                    Write-Host "  Found $(($locks | Measure-Object).Count) resource locks. Removing locks..." -ForegroundColor Yellow
                    $locks | ForEach-Object {
                        Write-Host "  Removing lock: $($_.Name)" -ForegroundColor Yellow
                        
                        # Check if RemoveLocks parameter is set either at function level or script level
                        if ($PSBoundParameters.ContainsKey('RemoveLocks') -and $PSBoundParameters['RemoveLocks'] -or 
                            $Script:RemoveLocks -or (Get-Variable -Name RemoveLocks -Scope Script -ErrorAction SilentlyContinue)) {
                            try {
                                Remove-AzResourceLock -LockId $_.LockId -Force -ErrorAction Stop
                                Write-Host "    Lock removed: $($_.Name)" -ForegroundColor Green
                            }
                            catch {
                                Write-Warning "    Failed to remove lock '$($_.Name)': $($_.Exception.Message)"
                            }
                        }
                        else {
                            Write-Host "    (Report only) Lock detected: $($_.Name) - not removed. Set \$RemoveLocks = \$true to remove locks." -ForegroundColor Yellow
                        }
                    }
                }
                
                # 6. Finally, attempt to delete the resource group
                Write-Host "  [6/6] Deleting resource group..." -ForegroundColor Yellow
                try {
                    if ($Async) {
                        # Start the deletion as a job to run asynchronously
                        $job = Remove-AzResourceGroup -Name $ResourceGroupName -Force -AsJob
                        Write-Host "Resource group deletion started as asynchronous job. Job ID: $($job.Id)" -ForegroundColor Yellow
                        return $job
                    }
                    else {
                        # Run deletion synchronously (blocking)
                        Write-Host "Deleting resource group synchronously..." -ForegroundColor Yellow
                        Remove-AzResourceGroup -Name $ResourceGroupName -Force -Verbose
                        Write-Host "Resource group $ResourceGroupName deleted successfully." -ForegroundColor Green
                        return $null
                    }
                }
                catch {
                    $errorMsg = $_.Exception.Message
                    if ($errorMsg -like "*Conflict*" -or $errorMsg -like "*409*") {
                        Write-Warning "Conflict detected when trying to delete resource group '$ResourceGroupName'"
                        Write-Warning "This may be due to resources still in use or in transition state."
                        Write-Warning "Error details: $errorMsg"
                        
                        # Try with force deletion of compute resources
                        Write-Host "  Attempting with forced deletion of compute resources..." -ForegroundColor Yellow
                        try {
                            if ($Async) {
                                $job = Remove-AzResourceGroup -Name $ResourceGroupName -Force -AsJob -ForceDeletionType "Microsoft.Compute/virtualMachines,Microsoft.Compute/virtualMachineScaleSets"
                                return $job
                            }
                            else {
                                Remove-AzResourceGroup -Name $ResourceGroupName -Force -ForceDeletionType "Microsoft.Compute/virtualMachines,Microsoft.Compute/virtualMachineScaleSets" -Verbose
                                Write-Host "Resource group $ResourceGroupName deleted successfully with force deletion." -ForegroundColor Green
                                return $null
                            }
                        }
                        catch {
                            Write-Error "Forced deletion also failed: $_"
                        }
                    }
                    else {
                        Write-Error "Failed to delete resource group: $_"
                    }
                }
                
                return $null
            }
        }
        catch {
            Write-Error "Failed to delete resource group '$ResourceGroupName': $_"
        }
    }
}

# Function to detect Recovery Services vaults in a resource group
function Get-RecoveryServicesVaultsInResourceGroup {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName
    )
    
    try {
        # Get all Recovery Services vaults in the resource group
        $vaults = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        
        if ($vaults -and $vaults.Count -gt 0) {
            Write-Host "  Found $($vaults.Count) Recovery Services vault(s) in resource group '$ResourceGroupName'" -ForegroundColor Yellow
            return $vaults
        }
        else {
            Write-Host "  No Recovery Services vaults found in resource group '$ResourceGroupName'" -ForegroundColor Green
            return $null
        }
    }
    catch {
        Write-Warning "  Error detecting Recovery Services vaults: $_"
        return $null
    }
}

# Function to display job progress with a progress bar
function Show-JobProgress {
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.Hashtable]$JobMap
    )
    
    $completed = 0
    $total = $JobMap.Count
    $spinner = @('|', '/', '-', '\')
    $spinnerIndex = 0
    
    # Store the initial job details 
    $jobStartTimes = @{}
    $initialKeys = @($JobMap.Keys)
    foreach ($key in $initialKeys) {
        $jobStartTimes[$key] = Get-Date
    }
    
    # Continue until all jobs complete
    while ($completed -lt $total) {
        # Clear the entire screen to start fresh with each update
        Clear-Host
        
        $completed = 0
        
        # Display header
        Write-Host "Resource Group Deletion Progress:" -ForegroundColor Cyan
        $jobTableHeader = "-" * 100
        Write-Host $jobTableHeader -ForegroundColor Cyan
        Write-Host ("{0,-40} {1,-15} {2,-30}" -f "RESOURCE GROUP", "STATUS", "ELAPSED TIME") -ForegroundColor Cyan
        Write-Host $jobTableHeader -ForegroundColor Cyan
        
        # Update the status of each job
        $currentKeys = @($JobMap.Keys)
        foreach ($rgName in $currentKeys) {
            $job = $JobMap[$rgName]
            $jobState = $job.State
            
            # Calculate elapsed time
            $elapsedTime = [math]::Round(((Get-Date) - $jobStartTimes[$rgName]).TotalSeconds)
            $hours = [math]::Floor($elapsedTime / 3600)
            $minutes = [math]::Floor(($elapsedTime % 3600) / 60)
            $seconds = [math]::Floor($elapsedTime % 60)
            $elapsedFormatted = "{0:00}:{1:00}:{2:00}" -f $hours, $minutes, $seconds
            
            # Determine color and symbol based on job state
            $statusColor = "Yellow"
            $statusSymbol = $spinner[$spinnerIndex % 4]
            
            if ($jobState -eq "Completed") {
                $statusColor = "Green"
                $statusSymbol = "√"
                $completed++
            }
            elseif ($jobState -eq "Failed") {
                $statusColor = "Red"
                $statusSymbol = "X"
                $completed++
            }
            
            # Display the status
            $statusText = "$statusSymbol $jobState"
            Write-Host ("{0,-40} " -f $rgName) -NoNewline
            Write-Host ("{0,-15} " -f $statusText) -ForegroundColor $statusColor -NoNewline
            Write-Host ("{0,-30}" -f $elapsedFormatted)
        }
        
        # Calculate and display overall progress
        $percentComplete = [math]::Round(($completed / $total) * 100)
        $progressBarWidth = 50
        $progressChars = [math]::Round(($percentComplete / 100) * $progressBarWidth)
        $progressBar = ("[" + ("=" * $progressChars).PadRight($progressBarWidth) + "]")
        
        Write-Host $jobTableHeader -ForegroundColor Cyan
        Write-Host ("Overall Progress: $progressBar $percentComplete% ($completed/$total complete)") -ForegroundColor Cyan
        
        # If not all jobs are completed yet, refresh
        if ($completed -lt $total) {
            Start-Sleep -Seconds 1
            $spinnerIndex++
            
            # Refresh job states
            $keysCopy = @($JobMap.Keys)
            foreach ($rgName in $keysCopy) {
                $JobMap[$rgName] = Get-Job -Id $JobMap[$rgName].Id
            }
        }
    }
    
    # Final status with all job results
    Clear-Host
    Write-Host "Final Resource Group Deletion Status:" -ForegroundColor Cyan
    $jobTableHeader = "-" * 100
    Write-Host $jobTableHeader -ForegroundColor Cyan
    Write-Host ("{0,-40} {1,-15} {2,-30}" -f "RESOURCE GROUP", "STATUS", "DETAILS") -ForegroundColor Cyan
    Write-Host $jobTableHeader -ForegroundColor Cyan
    
    $finalKeys = @($JobMap.Keys)
    foreach ($rgName in $finalKeys) {
        $job = $JobMap[$rgName]
        $statusColor = if ($job.State -eq "Completed") { "Green" } else { "Red" }
        
        # Get job output or error
        $result = "Completed successfully"
        if ($job.State -eq "Failed") {
            $jobError = $job | Receive-Job -ErrorAction SilentlyContinue -ErrorVariable jobErr 2>$null
            $result = $jobErr.Exception.Message -replace "`n", " " -replace "`r", ""
            if ($result.Length -gt 30) {
                $result = $result.Substring(0, 27) + "..."
            }
        }
        
        Write-Host ("{0,-40} " -f $rgName) -NoNewline
        Write-Host ("{0,-15} " -f $job.State) -ForegroundColor $statusColor -NoNewline
        Write-Host ("{0}" -f $result)
    }
    
    Write-Host $jobTableHeader -ForegroundColor Cyan
    Write-Host "All jobs completed." -ForegroundColor Cyan
}

# Function to categorize resource groups based on the 'keep' tag
function Get-CategorizedResourceGroups {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$ResourceGroupName
    )
    
    # Get resource groups based on whether a specific name was provided
    $allResourceGroups = if ($ResourceGroupName) {
        # If a specific resource group was provided, only process that one
        Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    }
    else {
        # Otherwise, get all resource groups
        Get-AzResourceGroup
    }

    $taggedResourceGroups = @()
    $untaggedResourceGroups = @()
    
    foreach ($rg in $allResourceGroups) {
        $tags = $rg.Tags
        if ($tags -and $tags['keep'] -eq 'true') {
            $taggedResourceGroups += $rg
        }
        else {
            $untaggedResourceGroups += $rg
        }
    }
    
    # Return a hashtable with the categorized results
    return @{
        Tagged   = $taggedResourceGroups
        Untagged = $untaggedResourceGroups
        All      = $allResourceGroups
    }
}

# Function to display resource groups in a formatted table with colors
function Show-ResourceGroupSummary {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [array]$TaggedResourceGroups,
        
        [Parameter(Mandatory = $false)]
        [array]$UntaggedResourceGroups
    )
    
    # Create combined groups array with status and color information
    $combinedGroups = @()
    foreach ($rg in $TaggedResourceGroups) {
        $combinedGroups += [PSCustomObject]@{
            Name   = $rg.ResourceGroupName
            Status = "Keep"
            Color  = "Red"
        }
    }

    foreach ($rg in $UntaggedResourceGroups) {
        $combinedGroups += [PSCustomObject]@{
            Name   = $rg.ResourceGroupName
            Status = "Delete"
            Color  = "Green"
        }
    }

    # Sort alphabetically by name
    $combinedGroups = $combinedGroups | Sort-Object -Property Name

    # Create a formatted table view
    Write-Host "`nResource Groups:" -ForegroundColor Cyan

    # Create a proper PowerShell table with colors
    $tableWidth = 60  # Adjust as needed for your display
    $headerBorder = "-" * $tableWidth

    # Display the header
    Write-Host $headerBorder -ForegroundColor Cyan
    Write-Host ("{0,-30} {1,-15}" -f "NAME", "STATUS") -ForegroundColor Cyan
    Write-Host $headerBorder -ForegroundColor Cyan

    # Display each row with appropriate color
    foreach ($rg in $combinedGroups) {
        $color = if ($rg.Color -eq "Red") { "Red" } else { "Green" }
        Write-Host ("{0,-30} {1,-15}" -f $rg.Name, $rg.Status) -ForegroundColor $color
    }

    Write-Host $headerBorder -ForegroundColor Cyan
    Write-Host "Total: $($combinedGroups.Count) resource groups" -ForegroundColor Cyan
    Write-Host "Keep: $($combinedGroups.Where{$_.Status -eq 'Keep'}.Count) resource groups" -ForegroundColor Red
    Write-Host "Delete: $($combinedGroups.Where{$_.Status -eq 'Delete'}.Count) resource groups" -ForegroundColor Green
    
    # Return the combined groups for further processing
    return $combinedGroups
}

#1. give the current context and ask user if he like to proceed with this, else ask to relogin and select a subscription from a list
$currentContext = Get-AzContext
if ($null -eq $currentContext) {
    Write-Host "No active Azure context found. Please log in."
    Connect-AzAccount
}
else {
    Write-Host "Current Azure context:$($currentContext)"
    Write-Host "Subscription: $($currentContext.Subscription)"
    Write-Host "SubscriptionName: $($currentContext.Subscription.Name)"
    $proceed = 'Y' #DEVSKIPPER    $proceed = Read-Host "Do you want to proceed with this context? (Y/N)"
    if ($proceed -ne 'Y') {
        Write-Host "Please log in and select a subscription."
        Connect-AzAccount
    }
}

#2. list all resource groups with tag keep=true
$categorizedGroups = Get-CategorizedResourceGroups -ResourceGroupName $ResourceGroupName
$taggedResourceGroups = $categorizedGroups.Tagged
$untaggedResourceGroups = $categorizedGroups.Untagged

#3. Print the all the tagged and untagged resource groups in the same table and order them alphabetically, the tagged should be red other green
$combinedGroups = Show-ResourceGroupSummary -TaggedResourceGroups $taggedResourceGroups -UntaggedResourceGroups $untaggedResourceGroups


# 4. Iterate through the list and delete the resource groups that are not tagged with keep=true
$deletionJobs = @{}

Write-Host "`nStarting deletion of resource groups..." -ForegroundColor Yellow
if ($Async) {
    Write-Host "Running in ASYNCHRONOUS mode" -ForegroundColor Cyan
}
else {
    Write-Host "Running in SYNCHRONOUS mode" -ForegroundColor Cyan
}

## START Iterate over RG's ##
foreach ($rg in $combinedGroups) {
    if ($rg.Status -eq "Delete") {
        try {
            # Call the function to delete the resource group
            $job = Remove-ResourceGroupSafely -ResourceGroupName $rg.Name -Async:$Async -RemoveLocks:$RemoveLocks
            if ($job) {
                $deletionJobs[$rg.Name] = $job
            }
        }
        catch {
            Write-Warning "Error trying to delete resource group '$($rg.Name)': $_"
            Write-Host "  Continuing with next resource group..." -ForegroundColor Yellow
        }
    }
}

# 5. Check if there are any deletion jobs to monitor
if ($deletionJobs.Count -gt 0) {
    # Monitor and display progress of all jobs
    Show-JobProgress -JobMap $deletionJobs
}
elseif ($combinedGroups.Where{ $_.Status -eq 'Delete' }.Count -gt 0) {
    # If we ran in synchronous mode, we won't have any jobs but may have deleted resource groups
    Write-Host "`nAll resource groups processed." -ForegroundColor Green
}
else {
    Write-Host "`nNo resource groups to delete." -ForegroundColor Yellow
}

# If we encountered any Azure CLI extension warnings, let the user know about the -UpdateAzExtensions parameter
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
    Write-Host "`nHINT: If you encountered Azure CLI extension warnings, try running this script with the -UpdateAzExtensions parameter:" -ForegroundColor Yellow
    Write-Host "      .\cleanup_resourcegroups.ps1 -UpdateAzExtensions" -ForegroundColor Cyan
}
