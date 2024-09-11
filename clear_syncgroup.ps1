# Connect to your Azure account
# Connect-AzAccount

# Define the resource group name and storage sync service name
param (
    [string]$resourceGroupName,
    [string]$storageSyncServiceName
)

Write-Output "Removing dependencies for Storage Sync Service: $storageSyncServiceName and resource group: $resourceGroupName"

# Function to unregister the server
function Unregister-Server {
    param (
        [string]$resourceGroupName,
        [string]$storageSyncServiceName,
        [string]$serverId
    )
    Write-Output "Unregistering Server: $serverId"
    ## Remove-AzStorageSyncRegisteredServer -ResourceGroupName $resourceGroupName -StorageSyncServiceName $storageSyncServiceName -ServerId $serverId -Force
    $RegisteredServer = Get-AzStorageSyncServer -ResourceGroupName $resourceGroupName -StorageSyncServiceName $storageSyncServiceName
    Unregister-AzStorageSyncServer -Force -ResourceGroupName $resourceGroupName -StorageSyncServiceName $storageSyncServiceName -ServerId $RegisteredServer.ServerId
    Write-Output "Unregistered Server: $serverId"
}


# Function to remove server endpoints in a sync group
function Remove-ServerEndpoints {
    param (
        [string]$resourceGroupName,
        [string]$storageSyncServiceName,
        [string]$syncGroupName
    )
    write-output "Removing Server Endpoints in Sync Group: $syncGroupName and resource group: $resourceGroupName and storage sync service: $storageSyncServiceName"
    $serverEndpoints = Get-AzStorageSyncServerEndpoint -ResourceGroupName $resourceGroupName -StorageSyncServiceName $storageSyncServiceName -SyncGroupName $syncGroupName
    foreach ($serverEndpoint in $serverEndpoints) {
        Unregister-Server -resourceGroupName $resourceGroupName -storageSyncServiceName $storageSyncServiceName -serverId $serverEndpoint.ServerResourceId
        Remove-AzStorageSyncServerEndpoint -ResourceGroupName $resourceGroupName -StorageSyncServiceName $storageSyncServiceName -SyncGroupName $syncGroupName -Name $serverEndpoint.ServerEndpointName -Force
        Write-Output "Removed Server Endpoint: $($serverEndpoint.ServerEndpointName)"
    }
}

# Function to remove cloud endpoints in a sync group
function Remove-CloudEndpoints {
    param (
        [string]$resourceGroupName,
        [string]$storageSyncServiceName,
        [string]$syncGroupName
    )
    $cloudEndpoints = Get-AzStorageSyncCloudEndpoint -ResourceGroupName $resourceGroupName -StorageSyncServiceName $storageSyncServiceName -SyncGroupName $syncGroupName
    foreach ($cloudEndpoint in $cloudEndpoints) {
        Remove-AzStorageSyncCloudEndpoint -ResourceGroupName $resourceGroupName -StorageSyncServiceName $storageSyncServiceName -SyncGroupName $syncGroupName -Name $cloudEndpoint.CloudEndpointName -Force
        Write-Output "Removed Cloud Endpoint: $($cloudEndpoint.CloudEndpointName)"
    }
}

# Function to remove sync groups in a storage sync service
function Remove-SyncGroups {
    param (
        [string]$resourceGroupName,
        [string]$storageSyncServiceName
    )
    Write-Output "Removing Sync Groups in Storage Sync Service: $storageSyncServiceName and resource group: $resourceGroupName"
    $syncGroups = Get-AzStorageSyncGroup -ResourceGroupName $resourceGroupName -StorageSyncServiceName $storageSyncServiceName
    foreach ($syncGroup in $syncGroups) {
        # Remove server endpoints
        Remove-ServerEndpoints -resourceGroupName $resourceGroupName -storageSyncServiceName $storageSyncServiceName -syncGroupName $syncGroup.SyncGroupName
        # Remove cloud endpoints
        Remove-CloudEndpoints -resourceGroupName $resourceGroupName -storageSyncServiceName $storageSyncServiceName -syncGroupName $syncGroup.SyncGroupName
        # Remove sync group
        Remove-AzStorageSyncGroup -ResourceGroupName $resourceGroupName -StorageSyncServiceName $storageSyncServiceName -Name $syncGroup.SyncGroupName -Force
        Write-Output "Removed Sync Group: $($syncGroup.SyncGroupName)"
    }
}

# Main script to remove the storage sync service and its dependencies
Write-Output "Removing dependencies for Storage Sync Service: $storageSyncServiceName"
Remove-SyncGroups -resourceGroupName $resourceGroupName -storageSyncServiceName $storageSyncServiceName

Write-Output "Removing Storage Sync Service: $storageSyncServiceName"
Remove-AzStorageSyncService -ResourceGroupName $resourceGroupName -Name $storageSyncServiceName -Force

Write-Output "Storage Sync Service and all its dependencies have been removed."