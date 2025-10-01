<#
.SYNOPSIS
    Safely cleans up and deletes an Azure Recovery Services vault and all its contents.

.DESCRIPTION
    This script safely cleans up and deletes an Azure Recovery Services vault by:
    - Disabling soft delete feature
    - Recovering items in soft delete state
    - Disabling security features
    - Removing all backup items (Azure VM, SQL, SAP HANA, File Share)
    - Removing all ASR (Azure Site Recovery) items
    - Removing private endpoints
    - Deleting the vault

.PARAMETER VaultName
    Name of the Recovery Services vault to delete

.PARAMETER ResourceGroup
    Name of the resource group containing the vault

.PARAMETER Subscription
    Name of the subscription containing the vault

.PARAMETER SubscriptionId
    ID of the subscription containing the vault

.PARAMETER Force
    Switch to automatically update required modules without prompting

.PARAMETER PassThru
    Switch to return $true or $false indicating success or failure

.EXAMPLE
    .\cleanup_vault.ps1 -VaultName "my-vault" -ResourceGroup "my-rg" -Subscription "my-sub"

.EXAMPLE
    .\cleanup_vault.ps1 -VaultName "my-vault" -ResourceGroup "my-rg" -SubscriptionId "12345-67890-12345"

.EXAMPLE
    $result = .\cleanup_vault.ps1 -VaultName "my-vault" -ResourceGroup "my-rg" -PassThru

.NOTES
    Requires PowerShell 7 or higher and Az.RecoveryServices 5.3.0+ and Az.Network 4.15.0+
    Script will verify and can automatically update the required module versions with -Force
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false, Position = 0, HelpMessage = "Name of the Recovery Services vault to delete")]
    [string]$VaultName,
    
    [Parameter(Mandatory = $false, Position = 1, HelpMessage = "Name of the resource group containing the vault")]
    [string]$ResourceGroup,
    
    [Parameter(Mandatory = $false, Position = 2, HelpMessage = "Name of the subscription containing the vault")]
    [string]$Subscription,
    
    [Parameter(Mandatory = $false, Position = 3, HelpMessage = "ID of the subscription containing the vault")]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $false)]
    [switch]$Force,
    
    [Parameter(Mandatory = $false)]
    [switch]$PassThru
)

# Function for vault cleanup
function Remove-RecoveryServicesVaultSafely {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [Microsoft.Azure.Commands.RecoveryServices.ARSVault]$Vault,
        
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )
    
    try {
        if ($PSCmdlet.ShouldProcess($Vault.Name, "Remove Recovery Services Vault")) {
            Write-Host "  Beginning cleanup of vault: $($Vault.Name)" -ForegroundColor Yellow
            $VaultName = $Vault.Name
            $ResourceGroup = $Vault.ResourceGroupName
            
            # Get current subscription ID
            $currentSubscriptionId = (Get-AzContext).Subscription.Id
            
            # Check for module versions
            Write-Host "  Checking required module versions..." -ForegroundColor Yellow
            $RSmodule = Get-Module -Name Az.RecoveryServices -ListAvailable
            $NWmodule = Get-Module -Name Az.Network -ListAvailable
            $RSversion = $RSmodule.Version.ToString()
            $NWversion = $NWmodule.Version.ToString()
            
            if ($RSversion -lt "5.3.0") {
                Write-Warning "Az.RecoveryServices module version $RSversion is less than required version 5.3.0"
                if ($Force) {
                    Write-Host "  Updating Az.RecoveryServices module..." -ForegroundColor Yellow
                    Install-Module -Name Az.RecoveryServices -Repository PSGallery -Force -AllowClobber
                    Import-Module -Name Az.RecoveryServices -Force
                } else {
                    Write-Error "Please update Az.RecoveryServices module to version 5.3.0 or higher. Use -Force to auto-update."
                    return $false
                }
            }
            
            if ($NWversion -lt "4.15.0") {
                Write-Warning "Az.Network module version $NWversion is less than required version 4.15.0"
                if ($Force) {
                    Write-Host "  Updating Az.Network module..." -ForegroundColor Yellow
                    Install-Module -Name Az.Network -Repository PSGallery -Force -AllowClobber
                    Import-Module -Name Az.Network -Force
                } else {
                    Write-Error "Please update Az.Network module to version 4.15.0 or higher. Use -Force to auto-update."
                    return $false
                }
            }
            
            # Set vault context
            Write-Host "  Setting vault context..." -ForegroundColor Yellow
            Set-AzRecoveryServicesAsrVaultContext -Vault $Vault
            
            # Check soft delete state and disable if necessary
            try {
                Write-Host "  Disabling soft delete..." -ForegroundColor Yellow
                Set-AzRecoveryServicesVaultProperty -VaultId $Vault.ID -SoftDeleteFeatureState Disable
                Write-Host "  Soft delete disabled for vault: $VaultName" -ForegroundColor Green
                
                # Restore items in soft delete state
                $containerSoftDelete = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $Vault.ID | Where-Object { $_.DeleteState -eq "ToBeDeleted" }
                foreach ($softitem in $containerSoftDelete) {
                    Write-Host "  Undoing soft delete for item: $($softitem.Name)" -ForegroundColor Yellow
                    Undo-AzRecoveryServicesBackupItemDeletion -Item $softitem -VaultId $Vault.ID -Force
                }
                
                # MSSQL items soft delete
                $containerSoftDeleteSql = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType MSSQL -VaultId $Vault.ID | Where-Object { $_.DeleteState -eq "ToBeDeleted" }
                foreach ($softitemsql in $containerSoftDeleteSql) {
                    Write-Host "  Undoing soft delete for SQL item: $($softitemsql.Name)" -ForegroundColor Yellow
                    Undo-AzRecoveryServicesBackupItemDeletion -Item $softitemsql -VaultId $Vault.ID -Force
                }
            } catch {
                Write-Warning "  Error managing soft delete: $_"
                # Continue with the process even if this fails
            }
            
            # Disable security features
            Write-Host "  Disabling security features..." -ForegroundColor Yellow
            Set-AzRecoveryServicesVaultProperty -VaultId $Vault.ID -DisableHybridBackupSecurityFeature $true
            
            # Clean up backup items and servers
            # Azure VM backups
            $backupItemsVM = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $Vault.ID
            foreach ($item in $backupItemsVM) {
                Write-Host "  Removing Azure VM backup: $($item.Name)" -ForegroundColor Yellow
                Disable-AzRecoveryServicesBackupProtection -Item $item -VaultId $Vault.ID -RemoveRecoveryPoints -Force
            }
            Write-Host "  Processed Azure VM backups" -ForegroundColor Green
            
            # SQL Server backups
            $backupItemsSQL = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType MSSQL -VaultId $Vault.ID
            foreach ($item in $backupItemsSQL) {
                Write-Host "  Removing SQL Server backup: $($item.Name)" -ForegroundColor Yellow
                Disable-AzRecoveryServicesBackupProtection -Item $item -VaultId $Vault.ID -RemoveRecoveryPoints -Force
            }
            $protectableItemsSQL = Get-AzRecoveryServicesBackupProtectableItem -WorkloadType MSSQL -VaultId $Vault.ID | Where-Object { $_.IsAutoProtected -eq $true }
            foreach ($item in $protectableItemsSQL) {
                Write-Host "  Disabling auto-protection for SQL item: $($item.Name)" -ForegroundColor Yellow
                Disable-AzRecoveryServicesBackupAutoProtection -BackupManagementType AzureWorkload -WorkloadType MSSQL -InputItem $item -VaultId $Vault.ID
            }
            $backupContainersSQL = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVMAppContainer -VaultId $Vault.ID | Where-Object { $_.ExtendedInfo.WorkloadType -eq "SQL" }
            foreach ($item in $backupContainersSQL) {
                Write-Host "  Unregistering SQL container: $($item.Name)" -ForegroundColor Yellow
                Unregister-AzRecoveryServicesBackupContainer -Container $item -Force -VaultId $Vault.ID
            }
            Write-Host "  Processed SQL Server backups" -ForegroundColor Green
            
            # SAP HANA backups
            $backupItemsSAP = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType SAPHanaDatabase -VaultId $Vault.ID
            foreach ($item in $backupItemsSAP) {
                Write-Host "  Removing SAP HANA backup: $($item.Name)" -ForegroundColor Yellow
                Disable-AzRecoveryServicesBackupProtection -Item $item -VaultId $Vault.ID -RemoveRecoveryPoints -Force
            }
            $backupContainersSAP = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVMAppContainer -VaultId $Vault.ID | Where-Object { $_.ExtendedInfo.WorkloadType -eq "SAPHana" }
            foreach ($item in $backupContainersSAP) {
                Write-Host "  Unregistering SAP HANA container: $($item.Name)" -ForegroundColor Yellow
                Unregister-AzRecoveryServicesBackupContainer -Container $item -Force -VaultId $Vault.ID
            }
            Write-Host "  Processed SAP HANA backups" -ForegroundColor Green
            
            # Azure File Share backups
            $backupItemsAFS = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureStorage -WorkloadType AzureFiles -VaultId $Vault.ID
            foreach ($item in $backupItemsAFS) {
                Write-Host "  Removing Azure File Share backup: $($item.Name)" -ForegroundColor Yellow
                Disable-AzRecoveryServicesBackupProtection -Item $item -VaultId $Vault.ID -RemoveRecoveryPoints -Force
            }
            # Storage Accounts
            $StorageAccounts = Get-AzRecoveryServicesBackupContainer -ContainerType AzureStorage -VaultId $Vault.ID
            foreach ($item in $StorageAccounts) {
                Write-Host "  Unregistering Storage Account: $($item.Name)" -ForegroundColor Yellow
                Unregister-AzRecoveryServicesBackupContainer -container $item -Force -VaultId $Vault.ID
            }
            Write-Host "  Processed Azure File Shares" -ForegroundColor Green
            
            # MARS Servers
            $backupServersMARS = Get-AzRecoveryServicesBackupContainer -ContainerType "Windows" -BackupManagementType MAB -VaultId $Vault.ID
            foreach ($item in $backupServersMARS) {
                Write-Host "  Unregistering MARS Server: $($item.Name)" -ForegroundColor Yellow
                Unregister-AzRecoveryServicesBackupContainer -Container $item -Force -VaultId $Vault.ID
            }
            Write-Host "  Processed MARS Servers" -ForegroundColor Green
            
            # Azure Backup Servers (MAB)
            $backupServersMABS = Get-AzRecoveryServicesBackupManagementServer -VaultId $Vault.ID | Where-Object { $_.BackupManagementType -eq "AzureBackupServer" }
            foreach ($item in $backupServersMABS) {
                Write-Host "  Unregistering MAB Server: $($item.Name)" -ForegroundColor Yellow
                Unregister-AzRecoveryServicesBackupManagementServer -AzureRmBackupManagementServer $item -VaultId $Vault.ID
            }
            Write-Host "  Processed MAB Servers" -ForegroundColor Green
            
            # DPM Servers
            $backupServersDPM = Get-AzRecoveryServicesBackupManagementServer -VaultId $Vault.ID | Where-Object { $_.BackupManagementType -eq "SCDPM" }
            foreach ($item in $backupServersDPM) {
                Write-Host "  Unregistering DPM Server: $($item.Name)" -ForegroundColor Yellow
                Unregister-AzRecoveryServicesBackupManagementServer -AzureRmBackupManagementServer $item -VaultId $Vault.ID
            }
            Write-Host "  Processed DPM Servers" -ForegroundColor Green
            
            # Removal of ASR Items
            Write-Host "  Processing Azure Site Recovery (ASR) items..." -ForegroundColor Yellow
            $fabricObjects = Get-AzRecoveryServicesAsrFabric
            if ($null -ne $fabricObjects) {
                # First DisableDR all VMs
                foreach ($fabricObject in $fabricObjects) {
                    $containerObjects = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabricObject
                    foreach ($containerObject in $containerObjects) {
                        $protectedItems = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $containerObject
                        # DisableDR all protected items
                        foreach ($protectedItem in $protectedItems) {
                            Write-Host "    Removing ASR protected item: $($protectedItem.Name)" -ForegroundColor Yellow
                            Remove-AzRecoveryServicesAsrReplicationProtectedItem -InputObject $protectedItem -Force
                        }
                        
                        $containerMappings = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $containerObject
                        # Remove all Container Mappings
                        foreach ($containerMapping in $containerMappings) {
                            Write-Host "    Removing container mapping: $($containerMapping.Name)" -ForegroundColor Yellow
                            Remove-AzRecoveryServicesAsrProtectionContainerMapping -InputObject $containerMapping -Force
                        }
                    }
                    
                    $NetworkObjects = Get-AzRecoveryServicesAsrNetwork -Fabric $fabricObject
                    foreach ($networkObject in $NetworkObjects) {
                        # Get the PrimaryNetwork
                        $PrimaryNetwork = Get-AzRecoveryServicesAsrNetwork -Fabric $fabricObject -FriendlyName $networkObject
                        $NetworkMappings = Get-AzRecoveryServicesAsrNetworkMapping -Network $PrimaryNetwork
                        foreach ($networkMappingObject in $NetworkMappings) {
                            Write-Host "    Removing network mapping: $($networkMappingObject.Name)" -ForegroundColor Yellow
                            Remove-AzRecoveryServicesAsrNetworkMapping -InputObject $networkMappingObject -Force
                        }
                    }
                    # Remove Fabric
                    Write-Host "    Removing fabric: $($fabricObject.FriendlyName)" -ForegroundColor Yellow
                    Remove-AzRecoveryServicesAsrFabric -InputObject $fabricObject -Force
                }
            }
            Write-Host "  Processed ASR items" -ForegroundColor Green
            
            # Remove private endpoints
            $pvtendpoints = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $Vault.ID
            foreach ($item in $pvtendpoints) {
                try {
                    $penamesplit = $item.Name.Split(".")
                    $pename = $penamesplit[0]
                    Write-Host "  Removing private endpoint connection: $($item.Name)" -ForegroundColor Yellow
                    Remove-AzPrivateEndpointConnection -ResourceId $item.Id -Force
                    Write-Host "  Removing private endpoint: $pename" -ForegroundColor Yellow
                    Remove-AzPrivateEndpoint -Name $pename -ResourceGroupName $ResourceGroup -Force
                } catch {
                    Write-Warning "  Error removing private endpoint: $_"
                }
            }
            Write-Host "  Processed private endpoints" -ForegroundColor Green
            
            # Do a final verification
            $finalCheck = $true
            
            # Check for any remaining backup items
            $backupItemsVMFin = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $Vault.ID
            if ($backupItemsVMFin.count -ne 0) { 
                Write-Warning "$($backupItemsVMFin.count) Azure VM backups still present in vault."
                $finalCheck = $false
            }
            
            $backupItemsSQLFin = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType MSSQL -VaultId $Vault.ID
            if ($backupItemsSQLFin.count -ne 0) {
                Write-Warning "$($backupItemsSQLFin.count) SQL Server backup items still present in vault."
                $finalCheck = $false
            }
            
            # Try to delete the vault using REST API as a final step
            try {
                # Get access token for REST API call
                Write-Host "  Attempting to delete vault using REST API..." -ForegroundColor Yellow
                $accessToken = Get-AzAccessToken
                $token = $accessToken.Token
                $authHeader = @{
                    'Content-Type'  = 'application/json'
                    'Authorization' = 'Bearer ' + $token
                }
                $restUri = "https://management.azure.com/subscriptions/$currentSubscriptionId/resourcegroups/$ResourceGroup/providers/Microsoft.RecoveryServices/vaults/$VaultName`?api-version=2021-06-01&operation=DeleteVaultUsingPS"
                $response = Invoke-RestMethod -Uri $restUri -Headers $authHeader -Method DELETE
                
                # Verify deletion
                Start-Sleep -Seconds 5
                $VaultDeleted = Get-AzRecoveryServicesVault -Name $VaultName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
                if ($VaultDeleted -eq $null) {
                    Write-Host "  Recovery Services Vault $VaultName successfully deleted" -ForegroundColor Green
                    return $true
                } else {
                    Write-Warning "  REST API deletion attempt completed but vault still exists."
                    if ($finalCheck) {
                        # If no items remain but vault couldn't be deleted, try normal removal
                        Write-Host "  Attempting standard vault deletion..." -ForegroundColor Yellow
                        Remove-AzRecoveryServicesVault -Vault $Vault -Force
                        return $true
                    }
                    return $false
                }
            } catch {
                Write-Warning "  Error deleting vault via REST API: $_"
                return $false
            }
        }
    } catch {
        Write-Error "Error removing Recovery Services vault: $_"
        return $false
    }
}

# Main script execution logic
Write-Host "Starting Azure Recovery Services Vault cleanup script" -ForegroundColor Cyan
Write-Host "Warning: Please ensure that you have at least PowerShell 7 before running this script." -ForegroundColor Yellow
Write-Host "Visit https://go.microsoft.com/fwlink/?linkid=2181071 for installation procedure." -ForegroundColor Yellow

# Parse named args from $args (makes it compatible with old delete_vault.ps1 calling convention)
$i = 0
while ($i -lt $args.Count) {
    switch ($args[$i].ToLower()) {
        '-vaultname' { if ($i + 1 -lt $args.Count) { $VaultName = $args[$i + 1] }; $i += 2; continue }
        '-subscription' { if ($i + 1 -lt $args.Count) { $Subscription = $args[$i + 1] }; $i += 2; continue }
        '-resourcegroup' { if ($i + 1 -lt $args.Count) { $ResourceGroup = $args[$i + 1] }; $i += 2; continue }
        '-subscriptionid' { if ($i + 1 -lt $args.Count) { $SubscriptionId = $args[$i + 1] }; $i += 2; continue }
        default { break }
    }
}

# Positional args (if still not set)
if (-not (Get-Variable -Name VaultName -ErrorAction SilentlyContinue) -and $args.Count -ge 1) { $VaultName = $args[0] }
if (-not (Get-Variable -Name Subscription -ErrorAction SilentlyContinue) -and $args.Count -ge 2) { $Subscription = $args[1] }
if (-not (Get-Variable -Name ResourceGroup -ErrorAction SilentlyContinue) -and $args.Count -ge 3) { $ResourceGroup = $args[2] }
if (-not (Get-Variable -Name SubscriptionId -ErrorAction SilentlyContinue) -and $args.Count -ge 4) { $SubscriptionId = $args[3] }

# Check if required parameters are provided
if (-not $VaultName) {
    $VaultName = Read-Host "Enter the name of the vault to delete"
}

if (-not $ResourceGroup) {
    $ResourceGroup = Read-Host "Enter the resource group of the vault"
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

# Get the vault object
$VaultToDelete = Get-AzRecoveryServicesVault -Name $VaultName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
if (-not $VaultToDelete) {
    Write-Error "Vault '$VaultName' not found in resource group '$ResourceGroup'"
    if ($PassThru) { return $false }
    exit 1
}

Write-Host "Found vault '$VaultName' in resource group '$ResourceGroup'" -ForegroundColor Green

# Call the function to clean up and delete the vault
$result = Remove-RecoveryServicesVaultSafely -Vault $VaultToDelete -Force:$Force

if ($result) {
    Write-Host "Vault '$VaultName' successfully cleaned up and deleted." -ForegroundColor Green
} else {
    Write-Warning "Failed to completely clean up vault '$VaultName'. Check for remaining items."
}

if ($PassThru) {
    return $result
}