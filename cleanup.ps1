# Connect to your Azure account
# Connect-AzAccount

param(
    [Parameter(Mandatory = $true)]  [String]$delete       
)
$tagname = 'keep'

# Define the resource group name
$resourceGroups = Get-AzResourceGroup | Where-Object { $_.Tags.$tagname -ne "true" }


# Function to remove network interface associations
function Remove-NsgAssociations {
    param (
        [string]$nsgId
    )
    $networkInterfaces = Get-AzNetworkInterface | Where-Object { $_.NetworkSecurityGroup.Id -eq $nsgId }
    foreach ($nic in $networkInterfaces) {
        $nic.NetworkSecurityGroup = $null
        Set-AzNetworkInterface -NetworkInterface $nic
        Write-Output "Removed NSG association from NIC: $($nic.Name)"
    }
}

foreach($resourceGroup in $resourceGroups) {
    $resourceGroupName = $resourceGroup.ResourceGroupName
    Write-Output "=== RG:  $($resourceGroupName) ==="
    # Get all resources in the resource group
    $resources = Get-AzResource -ResourceGroupName $resourceGroupName | Sort-Object -Property ResourceType
    if ($delete -eq "true"){
        # Delete each resource
        foreach ($resource in $resources) {
            Write-Output "Investigate to delete $($resource.Name)"
            try {
                if ($resource.ResourceType -eq "Microsoft.Network/networkSecurityGroups") {
                    # Remove NSG associations before deleting the NSG
                    Write-Output "Delete assosiations for $($resource.Name)"
                    Remove-NsgAssociations -nsgId $resource.ResourceId 
                }
                elseif ($resource.ResourceType -eq "Microsoft.StorageSync/storageSyncServices") {
                    # Remove sync groups before deleting the storage sync service
                    .\clear_syncgroup.ps1 -resourceGroupName $resourceGroupName -storageSyncServiceName  $resource.ResourceName
                }
                Write-Output "Deleting resource: $($resource.Name) of type $($resource.ResourceType)"
                Remove-AzResource -ResourceId $resource.ResourceId -Force -ErrorAction Stop 
                # Optionally, delete the resource group itself if it's empty
                try {
                    Write-Output "Deleting resource group: $resourceGroupName"
                    Remove-AzResourceGroup -Name $resourceGroupName -Force -ErrorAction Stop
                    Write-Output "Resource group $resourceGroupName deleted."
                }
                catch {
                    "Failed to delete resource group: $resourceGroupName. Error: $_"
                }
            }
            catch {
                "Failed to delete resource: $($resource.Name). Error: $_"
            }  
        }
    }
}


