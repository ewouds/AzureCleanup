<#
.SYNOPSIS
    Cleans up network resources and dependencies that can block Azure resource group deletion.

.DESCRIPTION
    This script identifies and removes problematic network resources in an Azure resource group, including:
    - Bare Metal Server resources
    - Network interfaces with specific naming patterns (e.g., "anf-*-nic-*")
    - Orphaned network interfaces (those not attached to VMs or private endpoints)
    - Other network resources that might prevent resource group deletion

.PARAMETER ResourceGroupName
    Name of the resource group containing network resources to clean up

.PARAMETER Subscription
    Name of the subscription containing the resource group

.PARAMETER SubscriptionId
    ID of the subscription containing the resource group

.PARAMETER Force
    Switch to force removal without prompting for confirmation

.PARAMETER PassThru
    Switch to return $true or $false indicating success or failure

.EXAMPLE
    .\cleanup_network.ps1 -ResourceGroupName "my-rg"

.EXAMPLE
    .\cleanup_network.ps1 -ResourceGroupName "my-rg" -Subscription "my-subscription"

.EXAMPLE
    $result = .\cleanup_network.ps1 -ResourceGroupName "my-rg" -Force -PassThru

.NOTES
    This script requires the Az PowerShell modules, specifically Az.Network and Az.Resources
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false, Position = 0, HelpMessage = "Name of the resource group containing network resources to clean up")]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $false, Position = 1, HelpMessage = "Name of the subscription containing the resource group")]
    [string]$Subscription,
    
    [Parameter(Mandatory = $false, Position = 2, HelpMessage = "ID of the subscription containing the resource group")]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $false)]
    [switch]$Force,
    
    [Parameter(Mandatory = $false)]
    [switch]$PassThru
)

function Remove-NetworkDependencies {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )
    
    $success = $true
    
    try {
        if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Remove network dependencies")) {
            Write-Host "Starting network dependency cleanup for resource group: $ResourceGroupName" -ForegroundColor Yellow
               
            # query all NIC's in this resource group
            $nics = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
            # iterate through the nics and find associated resources to this nic
            foreach ($nic in $nics) {
                # Find associated resources (e.g., VMs, private endpoints)
                $associatedResources = Get-AzResource -ResourceGroupName $ResourceGroupName | Where-Object {
                    $_.ResourceId -eq $nic.Id
                    Write-Host "Checking resource: $($_.Name) with ResourceId: $($_.ResourceId)" -ForegroundColor DarkGray
                }
               

                # If associated resources are found, remove them
                if ($associatedResources) {
                    Write-Host "Found associated resources for NIC '$($nic.Name)':" -ForegroundColor Yellow
                    $associatedResources | ForEach-Object {
                        Write-Host " - $_.Name" -ForegroundColor Green
                        # dissociate this nic from this resource
                        try {
                            # If the NIC is attached to a VM, detach it from the VM's network profile
                            if ($nic.VirtualMachine -and $nic.VirtualMachine.Id) {
                                $vm = Get-AzVM -ResourceId $nic.VirtualMachine.Id -ErrorAction SilentlyContinue
                                if ($vm) {
                                    Write-Host "Detaching NIC '$($nic.Name)' from VM '$($vm.Name)'" -ForegroundColor Yellow
                                    if ($PSCmdlet.ShouldProcess($vm.Name, "Remove NIC reference")) {
                                        $vm.NetworkProfile.NetworkInterfaces = $vm.NetworkProfile.NetworkInterfaces | Where-Object { $_.Id -ne $nic.Id }
                                        try {
                                            if (Get-Command Update-AzVM -ErrorAction SilentlyContinue) {
                                                Update-AzVM -ResourceGroupName $vm.ResourceGroupName -VM $vm -ErrorAction Stop
                                            } elseif (Get-Command Set-AzVM -ErrorAction SilentlyContinue) {
                                                Set-AzVM -ResourceGroupName $vm.ResourceGroupName -VM $vm -ErrorAction Stop
                                            } else {
                                                throw "No suitable cmdlet found to update VM."
                                            }
                                            Write-Host "Detached NIC from VM '$($vm.Name)'." -ForegroundColor Green
                                        } catch {
                                            Write-Warning "Failed to update VM '$($vm.Name)': $_"
                                            $success = $false
                                        }
                                    }
                                }
                            }
                            # If the associated resource is a private endpoint, remove the private endpoint (it owns the NIC)
                            elseif ($_.ResourceType -and ($_.ResourceType -match "Microsoft.Network/privateEndpoints" -or $_.Type -match "privateEndpoints")) {
                                Write-Host "Removing private endpoint '$($_.Name)' which references NIC '$($nic.Name)'" -ForegroundColor Yellow
                                if ($PSCmdlet.ShouldProcess($_.Name, "Remove private endpoint")) {
                                    try {
                                        Remove-AzResource -ResourceId $_.ResourceId -Force -ErrorAction Stop
                                        Write-Host "Removed private endpoint '$($_.Name)'" -ForegroundColor Green
                                    } catch {
                                        Write-Warning "Failed to remove private endpoint '$($_.Name)': $_"
                                        $success = $false
                                    }
                                }
                            }
                            # Fallback: if NIC is not attached to a VM and not owned by a private endpoint, remove the NIC if requested
                            else {
                                if (-not $nic.VirtualMachine) {
                                    $removeNic = $Force.IsPresent -or (Read-Host "Remove orphaned NIC '$($nic.Name)'? [y/N]" ) -match '^[Yy]'
                                    if ($removeNic) {
                                        Write-Host "Removing NIC '$($nic.Name)'" -ForegroundColor Yellow
                                        try {
                                            Remove-AzNetworkInterface -Name $nic.Name -ResourceGroupName $ResourceGroupName -Force -ErrorAction Stop
                                            Write-Host "Removed NIC '$($nic.Name)'" -ForegroundColor Green
                                        } catch {
                                            Write-Warning "Failed to remove NIC '$($nic.Name)': $_"
                                            $success = $false
                                        }
                                    }
                                }
                            }
                        } catch {
                            Write-Warning "Error while dissociating NIC '$($nic.Name)': $_"
                            $success = $false
                        }
                    }
                }
            }

        }
    } catch {
        Write-Error "Error during network dependency cleanup: $_"
        return $false
    }
}

# Main script execution logic
# Check if required parameters are provided
if (-not $ResourceGroupName) {
    $ResourceGroupName = Read-Host "Enter the name of the resource group to clean network resources from"
}

# Ensure we're connected to Azure
$azContext = Get-AzContext -ErrorAction SilentlyContinue
if (-not $azContext) {
    Write-Host "Not connected to Azure. Connecting..." -ForegroundColor Yellow
    Connect-AzAccount
}

# If subscription name is provided, use it
if ($Subscription) {
    Write-Host "Selecting subscription: $Subscription" -ForegroundColor Yellow
    Select-AzSubscription -SubscriptionName $Subscription
}
# If subscription ID is provided, use it
elseif ($SubscriptionId) {
    Write-Host "Selecting subscription ID: $SubscriptionId" -ForegroundColor Yellow
    Select-AzSubscription -SubscriptionId $SubscriptionId
}

# Verify resource group exists
$resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $resourceGroup) {
    Write-Error "Resource group '$ResourceGroupName' not found."
    if ($PassThru) { return $false }
    exit 1
}

Write-Host "Found resource group '$ResourceGroupName'" -ForegroundColor Green
Write-Host "Starting network dependency cleanup..." -ForegroundColor Cyan

# Call the cleanup function
$result = Remove-NetworkDependencies -ResourceGroupName $ResourceGroupName -Force:$Force

if ($PassThru) {
    return $result
}