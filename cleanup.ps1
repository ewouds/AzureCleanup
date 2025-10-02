<#
.SYNOPSIS
    Cleans up Azure resource groups by deleting those that are not tagged with keep=true.

.DESCRIPTION
    This script identifies Azure resource groups that are not tagged with keep=true and deletes them.
    It supports both synchronous and asynchronous deletion modes and can optionally remove resource locks.
    
    The script also handles Data Collection Rule (DCR) associations, which can prevent resource group deletion.
    DCR associations are automatically removed by default unless disabled with -RemoveDcrAssociations:$false.
    
    Recovery Services vaults in resource groups are automatically cleaned up and deleted before attempting
    to delete the resource group. This behavior can be controlled with the -RemoveVaults parameter.
    
    If you encounter issues with the Azure CLI extensions, use the -UpdateAzExtensions or -FixProblematicExtensions
    parameters to fix them.

.PARAMETER Async
    When specified, resource groups are deleted asynchronously in background jobs.
    Default is synchronous (blocking) deletion.

.PARAMETER RemoveLocks
    When specified, any resource locks on the resource groups will be removed before deletion.
    Default behavior is to only report locks without removing them.

.EXAMPLE
    .\cleanup_resourcegroups.ps1
    Deletes untagged resource groups synchronously without removing locks.

.EXAMPLE
    .\cleanup_resourcegroups.ps1 -Async
    Deletes untagged resource groups asynchronously in background jobs.

.EXAMPLE
    .\cleanup_resourcegroups.ps1 -RemoveLocks
    Deletes untagged resource groups synchronously and removes any resource locks.

.EXAMPLE
    .\cleanup_resourcegroups.ps1 -Async -RemoveLocks
    Deletes untagged resource groups asynchronously and removes any resource locks.

.PARAMETER RemoveDcrAssociations
    When specified, any Data Collection Rule associations will be removed before attempting to delete
    resource groups. This helps overcome a common deletion blocker when DCRs have cross-resource group
    associations. Default is $true (associations will be removed).

.PARAMETER UseCLI
    When specified (default is $true), the script will use Azure CLI commands to remove DCR associations.
    This is typically more reliable than using REST API.

.PARAMETER UseRESTAPI
    When specified (default is $false), the script will try to use REST API calls to remove DCR associations
    if CLI method fails or is disabled. This is less reliable and may encounter authentication issues.

.PARAMETER UpdateAzExtensions
    When specified, the script will attempt to update Azure CLI extensions before running the cleanup.
    This can help resolve issues with outdated extensions causing warnings or errors.

.PARAMETER FixProblematicExtensions
    When specified, the script will attempt to reinstall known problematic extensions such as containerapp.
    This can help resolve issues with extension import errors and warnings.

.PARAMETER ResourceGroupName
    When specified, the script will only process the specified resource group. This is useful for testing
    or targeting specific resource groups.

.PARAMETER CleanupMode
    Specifies the cleanup mode. Valid values are:
    - Full: Normal operation - removes DCR associations and deletes resource groups (default)
    - DCROnly: Only removes DCR associations without deleting resource groups
    - VaultOnly: Only cleans up Recovery Services vaults without deleting resource groups
    - NetAppOnly: Only cleans up Azure NetApp Files resources without deleting resource groups
    - OrderedFull: Performs cleanup in a specific order to handle complex dependencies

.PARAMETER RemoveVaults
    When specified (default is $true), any Recovery Services vaults in the resource group will be
    properly cleaned up and deleted before attempting to delete the resource group. This helps overcome
    common deletion blockers related to backup items and protected resources.
    Set to $false to skip vault deletion.
    
.PARAMETER RemoveNetApp
    When specified (default is $true), any Azure NetApp Files resources in the resource group will be
    properly cleaned up and deleted before attempting to delete the resource group. This helps overcome
    common deletion blockers related to NetApp resources with complex dependencies.
    Set to $false to skip NetApp resource cleanup.
    
.PARAMETER RemoveNetworkDependencies
    When specified (default is $false), the script will attempt to detect and remove network dependencies
    that might block resource group deletion, such as network interfaces used by Bare Metal Servers.
    This is an advanced option and should be used with caution.

.EXAMPLE
    .\cleanup_resourcegroups.ps1 -RemoveDcrAssociations:$false
    Deletes untagged resource groups synchronously without removing DCR associations (not recommended).

.EXAMPLE
    .\cleanup_resourcegroups.ps1 -UseCLI:$false -UseRESTAPI:$true
    Uses REST API instead of CLI for DCR association removal (less reliable).

.EXAMPLE
    .\cleanup_resourcegroups.ps1 -UpdateAzExtensions
    Updates Azure CLI extensions before running the cleanup to prevent extension-related warnings.

.EXAMPLE
    .\cleanup_resourcegroups.ps1 -FixProblematicExtensions
    Reinstalls known problematic extensions like containerapp to fix import errors and warnings.

.EXAMPLE
    .\cleanup_resourcegroups.ps1 -ResourceGroupName "my-test-rg"
    Only processes the specified resource group, deleting it if it's not tagged with keep=true.

.EXAMPLE
    .\cleanup_resourcegroups.ps1 -ResourceGroupName "my-test-rg" -CleanupMode "DCROnly"
    Only removes Data Collection Rule associations from the specified resource group without deleting it.
    
.EXAMPLE
    .\cleanup_resourcegroups.ps1 -ResourceGroupName "my-test-rg" -CleanupMode "VaultOnly"
    Only cleans up and deletes Recovery Services vaults in the specified resource group without deleting the group itself.
    
.EXAMPLE
    .\cleanup_resourcegroups.ps1 -ResourceGroupName "my-test-rg" -CleanupMode "NetAppOnly"
    Only cleans up Azure NetApp Files resources in the specified resource group without deleting the group itself.
    
.EXAMPLE
    .\cleanup_resourcegroups.ps1 -ResourceGroupName "my-test-rg" -CleanupMode "OrderedFull" -RemoveNetworkDependencies
    Deletes the resource group using an ordered approach that handles complex dependencies, including network dependencies.
    Only removes DCR associations from the specified resource group without deleting it.

.EXAMPLE
    .\cleanup_resourcegroups.ps1 -RemoveVaults:$false
    Deletes untagged resource groups without attempting to clean up Recovery Services vaults first.

.EXAMPLE
    .\cleanup_resourcegroups.ps1 -ResourceGroupName "my-backup-rg" -CleanupMode "VaultOnly"
    Only cleans up Recovery Services vaults in the specified resource group without deleting it.
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
                $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath "cleanup_network.ps1"
                & $scriptPath -ResourceGroupName $ResourceGroupName -Force -PassThru
                exit 0

                # 2. Second, check for network dependencies and remove them if RemoveNetworkDependencies is true
                if ((Get-Variable -Name RemoveNetworkDependencies -Scope Script -ErrorAction SilentlyContinue) -and $RemoveNetworkDependencies) {
                    Write-Host "  [2/5] Checking for network dependencies..." -ForegroundColor Yellow
                    & $scriptPath -ResourceGroupName $ResourceGroupName -Force -PassThru
                    # Use external cleanup_network.ps1 script
                    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath "cleanup_network.ps1"
                    if (Test-Path $scriptPath) {
                        $networkResult = & $scriptPath -ResourceGroupName $ResourceGroupName -Force -PassThru
                        
                        if (-not $networkResult) {
                            Write-Warning "  Network dependency cleanup completed with some failures."
                        }
                        else {
                            Write-Host "  Network dependency cleanup completed successfully." -ForegroundColor Green
                        }
                    }
                    else {
                        Write-Error "Required script 'cleanup_network.ps1' not found at $scriptPath"
                    }
                }

                
                
                # 2. Second, Remove any Data Collection Rule associations before attempting to delete if enabled
                if ($Script:RemoveDcrAssociations) {
                    Write-Host "  [2/5] Checking for Data Collection Rule associations..." -ForegroundColor Yellow
                    
                    $success = $false
                    
                    # Determine which method to use based on parameters
                    Write-Host "  Removing DCR associations using external script..." -ForegroundColor Yellow
                    $params = @{
                        ResourceGroupName = $ResourceGroupName
                        Force             = $true
                    }
                    
                    if ($Script:UseCLI) {
                        $params.Add("UseCLI", $true)
                    }
                    
                    if ($Script:UseRESTAPI) {
                        $params.Add("UseRESTAPI", $true)
                    }
                    
                    $success = Remove-DataCollectionRuleAssociations @params
                    
                    if (-not $success) {
                        Write-Host "  Warning: Failed to remove DCR associations. Resource group deletion may fail." -ForegroundColor Yellow
                        Write-Host "  You may need to remove associations manually from Azure Portal." -ForegroundColor Yellow
                    }
                }
                else {
                    Write-Host "  Skipping Data Collection Rule association check (disabled by parameter)" -ForegroundColor Yellow
                }
                
                # 3. Third, check for Recovery Services vaults and remove them if RemoveVaults is true
                if ((Get-Variable -Name RemoveVaults -Scope Script -ErrorAction SilentlyContinue) -and $RemoveVaults) {
                    Write-Host "  [3/5] Checking for Recovery Services vaults..." -ForegroundColor Yellow
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
                
                # 5. Finally, attempt to delete the resource group
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
