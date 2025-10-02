<#
.SYNOPSIS
    Cleans up network resources and dependencies that can block Azure resource group deletion.

.DESCRIPTION
    This script identifies and removes problematic network resources in an Azure resource group, including:
    - Network Security Groups (NSGs) and their associated resources
    - Bare Metal Server resources
    - Network interfaces with specific naming patterns (e.g., "anf-*-nic-*")
    - Orphaned network interfaces (those not attached to VMs or private endpoints)
    - Other network resources that might prevent resource group deletion

    Key Features:
    - Safe NSG removal with dependency analysis and user confirmation
    - Comprehensive network resource cleanup
    - Support for both interactive and automated execution
    - Detailed logging and error handling

    Available Functions:
    - Remove-AzureNSGWithDependencies: Standalone function for NSG cleanup with dependencies

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

.EXAMPLE
    # Use the standalone NSG cleanup function
    Remove-AzureNSGWithDependencies -ResourceGroupName "my-rg" -NSGName "my-nsg"

.NOTES
    This script requires the Az PowerShell modules, specifically Az.Network and Az.Resources
    
    For NSG deletion, see: https://aka.ms/deletensg
    
    Functions available for import:
    - Remove-AzureNSGWithDependencies
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
            Write-Host "Starting NIC's dependency cleanup for resource group: $ResourceGroupName" -ForegroundColor Yellow
               
            #1.  query all NIC's in this resource group
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
                                            }
                                            elseif (Get-Command Set-AzVM -ErrorAction SilentlyContinue) {
                                                Set-AzVM -ResourceGroupName $vm.ResourceGroupName -VM $vm -ErrorAction Stop
                                            }
                                            else {
                                                throw "No suitable cmdlet found to update VM."
                                            }
                                            Write-Host "Detached NIC from VM '$($vm.Name)'." -ForegroundColor Green
                                        }
                                        catch {
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
                                    }
                                    catch {
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
                                        }
                                        catch {
                                            Write-Warning "Failed to remove NIC '$($nic.Name)': $_"
                                            $success = $false
                                        }
                                    }
                                }
                            }
                        }
                        catch {
                            Write-Warning "Error while dissociating NIC '$($nic.Name)': $_"
                            $success = $false
                        }
                    }
                }
            }

            # Clean up NSGs and their associated resources
            $nsgCleanupResult = Remove-NetworkSecurityGroupsWithDependencies -ResourceGroupName $ResourceGroupName -Force:$Force
            if (-not $nsgCleanupResult) {
                $success = $false
            }

            # Clean virtual networks and their associated resources
            $vnetCleanupResult = Remove-VirtualNetworksWithDependencies -ResourceGroupName $ResourceGroupName -Force:$Force
            if (-not $vnetCleanupResult) {
                $success = $false
            }   
        }
    }
    catch {
        Write-Error "Error during network dependency cleanup: $_"
        return $false
    }
    
    return $success
}

function Remove-NetworkSecurityGroupsWithDependencies {
    <#
    .SYNOPSIS
        Removes Network Security Groups (NSGs) and handles their associated resources with user confirmation.

    .DESCRIPTION
        This function safely removes NSGs by first identifying and handling all associated resources:
        - Network interfaces associated with the NSG
        - Subnets that have the NSG associated
        - Virtual machines that might be affected
        
        The function provides detailed information about dependencies and asks for user confirmation
        before proceeding with any deletions, unless the Force parameter is used.

    .PARAMETER ResourceGroupName
        Name of the resource group containing the NSGs to clean up

    .PARAMETER NSGName
        Optional. Specific NSG name to target. If not provided, all NSGs in the resource group will be processed.

    .PARAMETER Force
        Switch to force removal without prompting for confirmation

    .EXAMPLE
        Remove-NetworkSecurityGroupsWithDependencies -ResourceGroupName "my-rg"

    .EXAMPLE
        Remove-NetworkSecurityGroupsWithDependencies -ResourceGroupName "my-rg" -NSGName "my-nsg" -Force

    .NOTES
        Based on Microsoft documentation: https://aka.ms/deletensg
        NSGs cannot be deleted if they are associated with subnets or network interfaces.
        This function handles the disassociation process safely.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $false)]
        [string]$NSGName,
        
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )
    
    $success = $true
    
    try {
        Write-Host "=== Network Security Group Cleanup ===" -ForegroundColor Cyan
        Write-Host "Analyzing NSGs and their dependencies in resource group: $ResourceGroupName" -ForegroundColor Yellow
        
        # Get NSGs to process
        if ($NSGName) {
            $nsgs = @(Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $NSGName -ErrorAction SilentlyContinue)
            if (-not $nsgs) {
                Write-Warning "NSG '$NSGName' not found in resource group '$ResourceGroupName'"
                return $false
            }
        }
        else {
            $nsgs = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        }
        
        if (-not $nsgs -or $nsgs.Count -eq 0) {
            Write-Host "No Network Security Groups found in resource group '$ResourceGroupName'" -ForegroundColor Green
            return $true
        }
        
        Write-Host "Found $($nsgs.Count) Network Security Group(s) to analyze" -ForegroundColor Yellow
        
        foreach ($nsg in $nsgs) {
            Write-Host "`n--- Processing NSG: '$($nsg.Name)' ---" -ForegroundColor Cyan
            
            $hasAssociations = $false
            $associatedResources = @()
            
            # Check for subnet associations
            if ($nsg.Subnets -and $nsg.Subnets.Count -gt 0) {
                $hasAssociations = $true
                Write-Host "  Associated Subnets:" -ForegroundColor Yellow
                foreach ($subnetRef in $nsg.Subnets) {
                    $subnetInfo = "    - Subnet ID: $($subnetRef.Id)"
                    Write-Host $subnetInfo -ForegroundColor White
                    $associatedResources += "Subnet: $($subnetRef.Id)"
                    
                    # Try to get more details about the subnet
                    try {
                        $subnetParts = $subnetRef.Id -split '/'
                        $vnetName = $subnetParts[8]
                        $subnetName = $subnetParts[10]
                        $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $vnetName -ErrorAction SilentlyContinue
                        if ($vnet) {
                            $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }
                            if ($subnet) {
                                Write-Host "      └─ Virtual Network: $vnetName, Subnet: $subnetName" -ForegroundColor Gray
                            }
                        }
                    }
                    catch {
                        Write-Host "      └─ Could not get detailed subnet information" -ForegroundColor Gray
                    }
                }
            }
            
            # Check for network interface associations
            if ($nsg.NetworkInterfaces -and $nsg.NetworkInterfaces.Count -gt 0) {
                $hasAssociations = $true
                Write-Host "  Associated Network Interfaces:" -ForegroundColor Yellow
                foreach ($nicRef in $nsg.NetworkInterfaces) {
                    $nicInfo = "    - NIC ID: $($nicRef.Id)"
                    Write-Host $nicInfo -ForegroundColor White
                    $associatedResources += "Network Interface: $($nicRef.Id)"
                    
                    # Try to get more details about the NIC and associated VM
                    try {
                        $nicParts = $nicRef.Id -split '/'
                        $nicName = $nicParts[-1]
                        $nic = Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName -Name $nicName -ErrorAction SilentlyContinue
                        if ($nic) {
                            Write-Host "      └─ NIC Name: $($nic.Name)" -ForegroundColor Gray
                            if ($nic.VirtualMachine -and $nic.VirtualMachine.Id) {
                                $vmParts = $nic.VirtualMachine.Id -split '/'
                                $vmName = $vmParts[-1]
                                Write-Host "      └─ Attached to VM: $vmName" -ForegroundColor Gray
                                $associatedResources += "Virtual Machine: $vmName"
                            }
                        }
                    }
                    catch {
                        Write-Host "      └─ Could not get detailed NIC information" -ForegroundColor Gray
                    }
                }
            }
            
            # Display security rules count
            $inboundRules = ($nsg.SecurityRules | Where-Object { $_.Direction -eq 'Inbound' }).Count
            $outboundRules = ($nsg.SecurityRules | Where-Object { $_.Direction -eq 'Outbound' }).Count
            Write-Host "  Security Rules: $inboundRules inbound, $outboundRules outbound" -ForegroundColor Gray
            
            if (-not $hasAssociations) {
                Write-Host "  ✓ No associations found - NSG can be safely deleted" -ForegroundColor Green
            }
            else {
                Write-Host "  ⚠ NSG has associations that must be removed first" -ForegroundColor Yellow
            }
            
            # Ask for confirmation if not using Force
            $proceed = $Force.IsPresent
            if (-not $proceed) {
                Write-Host "`nThe following associated resources were found for NSG '$($nsg.Name)':" -ForegroundColor Yellow
                foreach ($resource in $associatedResources) {
                    Write-Host "  • $resource" -ForegroundColor White
                }
                
                if ($hasAssociations) {
                    Write-Host "`nTo delete this NSG, all associations must be removed first." -ForegroundColor Yellow
                    Write-Host "This will:" -ForegroundColor Yellow
                    Write-Host "  1. Disassociate the NSG from all subnets" -ForegroundColor White
                    Write-Host "  2. Disassociate the NSG from all network interfaces" -ForegroundColor White
                    Write-Host "  3. Delete the NSG and its security rules" -ForegroundColor White
                    Write-Host "`nWarning: This may affect network connectivity for associated resources!" -ForegroundColor Red
                }
                
                $response = Read-Host "`nDo you want to proceed with removing NSG '$($nsg.Name)' and its associations? [y/N]"
                $proceed = $response -match '^[Yy]'
            }
            
            if ($proceed) {
                if ($PSCmdlet.ShouldProcess($nsg.Name, "Remove NSG and all associations")) {
                    Write-Host "`nProceeding with NSG removal..." -ForegroundColor Green
                    
                    try {
                        # Step 1: Disassociate from subnets
                        if ($nsg.Subnets -and $nsg.Subnets.Count -gt 0) {
                            Write-Host "  Disassociating NSG from subnets..." -ForegroundColor Yellow
                            foreach ($subnetRef in $nsg.Subnets) {
                                try {
                                    $subnetParts = $subnetRef.Id -split '/'
                                    $vnetName = $subnetParts[8]
                                    $subnetName = $subnetParts[10]
                                    
                                    $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $vnetName -ErrorAction Stop
                                    $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }
                                    
                                    if ($subnet -and $subnet.NetworkSecurityGroup) {
                                        $subnet.NetworkSecurityGroup = $null
                                        Set-AzVirtualNetwork -VirtualNetwork $vnet -ErrorAction Stop
                                        Write-Host "    ✓ Disassociated from subnet: $subnetName in VNet: $vnetName" -ForegroundColor Green
                                    }
                                }
                                catch {
                                    Write-Warning "    ✗ Failed to disassociate from subnet $($subnetRef.Id): $_"
                                    $success = $false
                                }
                            }
                        }
                        
                        # Step 2: Disassociate from network interfaces
                        if ($nsg.NetworkInterfaces -and $nsg.NetworkInterfaces.Count -gt 0) {
                            Write-Host "  Disassociating NSG from network interfaces..." -ForegroundColor Yellow
                            foreach ($nicRef in $nsg.NetworkInterfaces) {
                                try {
                                    $nicParts = $nicRef.Id -split '/'
                                    $nicName = $nicParts[-1]
                                    $rgNic = $nicParts[4]
                                     
                                    $nic = Get-AzNetworkInterface -ResourceGroupName $rgNic -Name $nicName -ErrorAction Stop
                                    $nic.NetworkSecurityGroup = $null
                                    Set-AzNetworkInterface -NetworkInterface $nic -ErrorAction Stop
                                    Write-Host "    ✓ Disassociated from network interface: $nicName" -ForegroundColor Green
                                }
                                catch {
                                    Write-Warning "    ✗ Failed to disassociate from NIC $($nicRef.Id): $_"
                                    $success = $false
                                }
                            }
                        }
                        
                        # Step 3: Delete the NSG
                        Write-Host "  Deleting NSG '$($nsg.Name)'..." -ForegroundColor Yellow
                        Remove-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $nsg.Name -Force -ErrorAction Stop
                        Write-Host "  ✓ Successfully deleted NSG '$($nsg.Name)'" -ForegroundColor Green
                        
                    }
                    catch {
                        Write-Warning "Failed to remove NSG '$($nsg.Name)': $_"
                        $success = $false
                    }
                }
            }
            else {
                Write-Host "Skipping NSG '$($nsg.Name)'" -ForegroundColor Yellow
            }
        }        
        Write-Host "`n=== NSG Cleanup Complete ===" -ForegroundColor Cyan
        
    }
    catch {
        Write-Error "Error during NSG cleanup: $_"
        return $false
    }
    
    return $success
}

function Remove-AzureNSGWithDependencies {
    <#
    .SYNOPSIS
        Standalone function to delete Azure Network Security Groups and their associated resources safely.

    .DESCRIPTION
        This function provides a comprehensive solution for removing NSGs while properly handling all dependencies.
        It identifies all associated resources (subnets, network interfaces, VMs) and provides detailed information
        to the user before proceeding with removal. The function follows Microsoft best practices for NSG deletion.

        Features:
        - Identifies all NSG associations (subnets, network interfaces)
        - Shows detailed information about affected resources
        - Requests user confirmation with clear impact explanation
        - Safely disassociates NSG from all resources before deletion
        - Supports both single NSG and bulk deletion
        - Provides detailed logging and error handling

    .PARAMETER ResourceGroupName
        Name of the resource group containing the NSGs to delete

    .PARAMETER NSGName
        Optional. Name of a specific NSG to delete. If not provided, all NSGs in the resource group will be processed.

    .PARAMETER SubscriptionName
        Optional. Name of the Azure subscription to use

    .PARAMETER SubscriptionId
        Optional. ID of the Azure subscription to use

    .PARAMETER Force
        Skip confirmation prompts and proceed with deletion

    .PARAMETER WhatIf
        Show what would be deleted without actually performing the deletion

    .EXAMPLE
        Remove-AzureNSGWithDependencies -ResourceGroupName "my-rg"
        # Analyzes and removes all NSGs in the resource group with user confirmation

    .EXAMPLE
        Remove-AzureNSGWithDependencies -ResourceGroupName "my-rg" -NSGName "my-nsg" -Force
        # Removes specific NSG without confirmation

    .EXAMPLE
        Remove-AzureNSGWithDependencies -ResourceGroupName "my-rg" -WhatIf
        # Shows what would be deleted without actually deleting anything

    .EXAMPLE
        Remove-AzureNSGWithDependencies -ResourceGroupName "my-rg" -SubscriptionName "my-subscription"
        # Removes NSGs in specific subscription

    .NOTES
        Author: Azure Cleanup Script
        Based on: https://aka.ms/deletensg
        
        Prerequisites:
        - Az.Network PowerShell module
        - Az.Resources PowerShell module
        - Appropriate Azure permissions (Network Contributor role or equivalent)
        
        Warning: This function will modify network security configurations. 
        Ensure you understand the impact before proceeding.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Name of the resource group containing NSGs")]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $false, HelpMessage = "Specific NSG name to delete")]
        [string]$NSGName,
        
        [Parameter(Mandatory = $false, HelpMessage = "Azure subscription name")]
        [string]$SubscriptionName,
        
        [Parameter(Mandatory = $false, HelpMessage = "Azure subscription ID")]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $false, HelpMessage = "Skip confirmation prompts")]
        [switch]$Force,
        
        [Parameter(Mandatory = $false, HelpMessage = "Show what would be deleted without deleting")]
        [switch]$WhatIf
    )
    
    begin {
        Write-Host "Azure NSG Cleanup Tool" -ForegroundColor Cyan
        Write-Host "======================" -ForegroundColor Cyan
        
        # Check Azure connection
        $azContext = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $azContext) {
            Write-Host "Not connected to Azure. Please connect..." -ForegroundColor Yellow
            try {
                Connect-AzAccount -ErrorAction Stop
                Write-Host "Successfully connected to Azure" -ForegroundColor Green
            }
            catch {
                Write-Error "Failed to connect to Azure: $_"
                return $false
            }
        }
        
        # Set subscription if provided
        if ($SubscriptionName) {
            Write-Host "Switching to subscription: $SubscriptionName" -ForegroundColor Yellow
            try {
                Select-AzSubscription -SubscriptionName $SubscriptionName -ErrorAction Stop
                Write-Host "Successfully switched to subscription: $SubscriptionName" -ForegroundColor Green
            }
            catch {
                Write-Error "Failed to switch to subscription '$SubscriptionName': $_"
                return $false
            }
        }
        elseif ($SubscriptionId) {
            Write-Host "Switching to subscription ID: $SubscriptionId" -ForegroundColor Yellow
            try {
                Select-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop
                Write-Host "Successfully switched to subscription ID: $SubscriptionId" -ForegroundColor Green
            }
            catch {
                Write-Error "Failed to switch to subscription '$SubscriptionId': $_"
                return $false
            }
        }
        
        # Verify resource group exists
        Write-Host "Verifying resource group: $ResourceGroupName" -ForegroundColor Yellow
        $resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $resourceGroup) {
            Write-Error "Resource group '$ResourceGroupName' not found in current subscription"
            return $false
        }
        Write-Host "✓ Resource group found: $ResourceGroupName" -ForegroundColor Green
    }
    
    process {
        try {
            # If WhatIf is specified, set the WhatIf preference
            if ($WhatIf) {
                $WhatIfPreference = $true
                Write-Host "`n=== WHATIF MODE: No changes will be made ===" -ForegroundColor Magenta
            }
            
            # Call the main NSG removal function
            $result = Remove-NetworkSecurityGroupsWithDependencies -ResourceGroupName $ResourceGroupName -NSGName $NSGName -Force:$Force
            
            if ($result) {
                Write-Host "`n✓ NSG cleanup completed successfully" -ForegroundColor Green
                return $true
            }
            else {
                Write-Warning "NSG cleanup completed with some errors. Check the output above for details."
                return $false
            }
        }
        catch {
            Write-Error "Fatal error during NSG cleanup: $_"
            return $false
        }
    }
    
    end {
        Write-Host "`nNSG cleanup operation finished." -ForegroundColor Cyan
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

# Export the standalone NSG cleanup function for use in other scripts
Export-ModuleMember -Function Remove-AzureNSGWithDependencies