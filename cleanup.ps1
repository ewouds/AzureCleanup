param(
    [Parameter(Mandatory = $true)]  [String]$delete       
)
$tenantId = "16b3c013-d300-468d-ac64-7eda0820b6d3"
$tagname = 'keep'


# Function to check if Azure credentials are valid
function Validate-AzureCredentials {
    $azAccessToken = Get-AzAccessToken -TenantId $tenantId
    if ($null -eq $azAccessToken) {
        Write-Output "No Azure context found. Please log in to your Azure account."
        Connect-AzAccount
    }
    elseif ($null -eq $azAccessToken.Token -or $azAccessToken.ExpiresOn -lt (Get-Date)) {
        Write-Output "Azure credentials have expired (".$azAccessToken.Token.ExpiresOn."). Please log in again."    
        Connect-AzAccount
    }
    else {
        Write-Output "Azure credentials are valid."
    }  
    Write-Output $azAccessToken
}

# Function to remove network interface associations
function Remove-NsgAssociations {
    param (
        [string]$nsgId
    )
    $networkInterfaces = Get-AzNetworkInterface | Where-Object { $_.NetworkSecurityGroup.Id -eq $nsgId }
    foreach ($nic in $networkInterfaces) {
        $nic.NetworkSecurityGroup = $null
        Set-AzNetworkInterface -NetworkInterface $nic
        Write-Host "Removed NSG association from NIC: $($nic.Name)"
    }
}

Validate-AzureCredentials

# Define the resource group name
$resourceGroups = Get-AzResourceGroup | Where-Object { $_.Tags.$tagname -ne "true" }
Write-Output "resourceGroups" + $resourceGroups


foreach ($resourceGroup in $resourceGroups) {
    $resourceGroupName = $resourceGroup.ResourceGroupName
    Write-Host "=== RG:  $($resourceGroupName) ===" -ForegroundColor Blue
    # Get all resources in the resource group
    $resources = Get-AzResource -ResourceGroupName $resourceGroupName | Sort-Object -Property ResourceType
    if ($delete -eq "true") {
        # Delete each resource
        foreach ($resource in $resources) {
            Write-Host "Investigate to delete $($resource.Name)"
            try {
                # Check for any locks
                $locks = Get-AzResourceLock -ResourceGroupName $resourceGroupName -ResourceName $resource.Name -ResourceType $resource.ResourceType

                # Remove the lock if it exists
                foreach ($lock in $locks) {
                    Remove-AzResourceLock -LockId $lock.LockId -Force
                    Write-Output "Removed lock '$($lock.Name)' on '$($resource.Name)'."
                }
            }
            catch {
                Write-host "Failed to delete lock '$($lock.Name)' on '$($resource.Name)'. Error: $_"  -ForegroundColor Red
            }
            try {
                if ($resource.ResourceType -eq "Microsoft.Network/networkSecurityGroups") {
                    # Remove NSG associations before deleting the NSG
                    Write-Host "Delete assosiations for $($resource.Name)"
                    Remove-NsgAssociations -nsgId $resource.ResourceId 
                }
                elseif ($resource.ResourceType -eq "Microsoft.StorageSync/storageSyncServices") {
                    .\clear_syncgroup.ps1 -resourceGroupName $resourceGroupName -storageSyncServiceName  $resource.ResourceName
                }
                elseif ($resource.ResourceType -eq "Microsoft.Insights/dataCollectionRules") {
                    .\clear_dcr.ps1 -resourceGroupName $resourceGroupName -dataCollectionRuleName  $resource.ResourceName
                }
                elseif ($resource.ResourceType -eq "Microsoft.RecoveryServices/vaults") {
                    .\clear_recover_service_vault.ps1 -resourceGroupName $resourceGroupName -VaultName  $resource.ResourceName
                }
                elseif ($resource.ResourceType -eq "Microsoft.DataProtection/BackupVaults") {
                    Write-Host "Get-AzDataProtectionBackupInstance -VaultName $($resource.ResourceName) -ResourceGroupName $($resourceGroupName) | Remove-AzDataProtectionBackupInstance"
                    Get-AzDataProtectionBackupInstance -VaultName $resource.ResourceName -ResourceGroupName $resourceGroupName | Remove-AzDataProtectionBackupInstance
                    Remove-AzDataProtectionBackupVault -resourceGroupName $resourceGroupName -VaultName $resource.ResourceName
                }
                
                
                Write-Host "Deleting resource: $($resource.Name) of type $($resource.ResourceType)"
                Remove-AzResource -ResourceId $resource.ResourceId -Force -ErrorAction Stop 
                # Optionally, delete the resource group itself if it's empty
                try {
                    Write-Host "Deleting resource group: $resourceGroupName"
                    Remove-AzResourceGroup -Name $resourceGroupName -Force -ErrorAction Stop
                    Write-Host "Resource group $resourceGroupName deleted."
                }
                catch {
                    Write-host "Failed to delete resource group: $resourceGroupName. Error: $_"  -ForegroundColor Red
                }
            }
            catch {
                Write-host "Failed to delete resource: $($resource.Name). Error: $_" -ForegroundColor Red
            }  
        }
    }
}


