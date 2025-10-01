# Import the Azure PowerShell module
Import-Module Az

# Set the necessary parameters
$resourceGroupName = "YourResourceGroupName"
$backupVaultName = "YourBackupVaultName"

# Confirm the details with the user
Write-Output "You are about to delete the Backup Vault '$($backupVaultName)' in Resource Group '$($resourceGroupName)'."
$confirmation = Read-Host "Type 'yes' to confirm"

if ($confirmation -eq 'yes') {
    try {
        # Validate the existence of the Backup Vault
        $backupVault = Get-AzRecoveryServicesVault -ResourceGroupName $resourceGroupName -Name $backupVaultName -ErrorAction Stop

        if ($null -ne $backupVault) {
            # Set the vault context
            Set-AzRecoveryServicesVaultContext -Vault $backupVault

            # Disable the soft delete feature
            Set-AzRecoveryServicesVaultProperty -VaultId $backupVault.ID -SoftDeleteFeatureState Disable
            Write-Output "Soft delete feature has been disabled for Backup Vault '$backupVaultName'."

            # Unregister all containers from the Backup Vault
            $containers = Get-AzRecoveryServicesBackupContainer -VaultId $backupVault.ID
            foreach ($container in $containers) {
                Unregister-AzRecoveryServicesBackupContainer -Container $container -Force
                Write-Output "Unregistered container '$($container.Name)' from Backup Vault '$backupVaultName'."
            }

            # Delete any private endpoints associated with the Backup Vault
            $privateEndpoints = Get-AzPrivateEndpoint -ResourceGroupName $resourceGroupName | Where-Object { $_.PrivateLinkServiceConnections.ResourceId -eq $backupVault.Id }
            foreach ($privateEndpoint in $privateEndpoints) {
                Remove-AzPrivateEndpoint -ResourceGroupName $resourceGroupName -Name $privateEndpoint.Name -Force
                Write-Output "Deleted private endpoint '$($privateEndpoint.Name)' associated with Backup Vault '$backupVaultName'."
            }

            # Delete the Backup Vault
            Remove-AzRecoveryServicesVault -Vault $backupVault
            Write-Output "Backup Vault '$backupVaultName' in Resource Group '$resourceGroupName' has been deleted."
        }
        else {
            Write-Output "Backup Vault '$backupVaultName' does not exist in Resource Group '$resourceGroupName'."
        }
    }
    catch {
        Write-Output "An error occurred: $_"
        Write-Output "Exception type: $($_.Exception.GetType().FullName)"
        Write-Output "Message: $($_.Exception.Message)"
        Write-Output "Stack Trace: $($_.Exception.StackTrace)"
    }
}
else {
    Write-Output "Operation cancelled by the user."
}