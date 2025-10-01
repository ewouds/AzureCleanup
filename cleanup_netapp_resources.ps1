<#
.SYNOPSIS
    Cleans up Azure NetApp Files resources in a specified resource group.

.DESCRIPTION
    This script identifies and cleans up Azure NetApp Files resources in a specified resource group.
    It removes resources in the correct dependency order:
    1. Volume backups
    2. Volumes
    3. Backup policies
    4. Backup vaults
    5. Capacity pools
    6. NetApp accounts
    
    This script can be called independently or from the main cleanup_resourcegroups.ps1 script.

.PARAMETER ResourceGroupName
    The name of the resource group containing NetApp resources to clean up.

.PARAMETER Force
    When specified, forces the removal of resources even if they have dependencies.
    This may be needed for resources that are in a failed state.

.EXAMPLE
    .\cleanup_netapp_resources.ps1 -ResourceGroupName "myResourceGroup"
    Cleans up NetApp resources in the specified resource group.

.EXAMPLE
    .\cleanup_netapp_resources.ps1 -ResourceGroupName "myResourceGroup" -Force
    Forces the cleanup of NetApp resources in the specified resource group.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $false)]
    [switch]$Force
)

# Function to detect NetApp resources in a resource group
function Get-NetAppResourcesInResourceGroup {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName
    )
    
    try {
        # Check if Az.NetAppFiles module is available
        $module = Get-Module -Name Az.NetAppFiles -ListAvailable
        if (-not $module) {
            Write-Warning "Az.NetAppFiles module not found. Installing module..."
            Install-Module -Name Az.NetAppFiles -Force -AllowClobber -Scope CurrentUser
            Import-Module -Name Az.NetAppFiles -Force
        }
        
        # Get all NetApp accounts in the resource group
        $accounts = Get-AzNetAppFilesAccount -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        
        if ($accounts -and $accounts.Count -gt 0) {
            Write-Host "  Found $($accounts.Count) NetApp account(s) in resource group '$ResourceGroupName'" -ForegroundColor Yellow
            
            $result = @{
                Accounts       = $accounts
                Pools          = @()
                Volumes        = @()
                BackupPolicies = @()
                BackupVaults   = @()
                Snapshots      = @()
                VolumeBackups  = @()
            }
            
            # Get capacity pools, volumes, and backup policies for each account
            foreach ($account in $accounts) {
                $accountName = $account.Name
                
                # Get capacity pools
                write-host "Get-AzNetAppFilesPool -ResourceGroupName $ResourceGroupName -AccountName $accountName -ErrorAction SilentlyContinue "
                $pools = Get-AzNetAppFilesPool -ResourceGroupName $ResourceGroupName -AccountName $accountName -ErrorAction SilentlyContinue
                if ($pools) {
                    $result.Pools += $pools
                    
                    # Get volumes for each pool
                    foreach ($pool in $pools) {
                        $poolName = $pool.Name.Split('/')[-1]
                       
                        $volumes = Get-AzNetAppFilesVolume -ResourceGroupName $ResourceGroupName -AccountName $accountName -PoolName $poolName -ErrorAction SilentlyContinue
                       
                        if ($volumes) {
                            $result.Volumes += $volumes
                            
                            # Get snapshots for each volume
                            foreach ($volume in $volumes) {
                                $volumeName = $volume.Name
                                $snapshots = Get-AzNetAppFilesSnapshot -ResourceGroupName $ResourceGroupName -AccountName $accountName -PoolName $poolName -VolumeName $volumeName -ErrorAction SilentlyContinue
                                if ($snapshots) {
                                    $result.Snapshots += $snapshots
                                }
                                
                                # Get volume backups if BackupId is present
                                if ($volume.BackupId) {
                                    try {
                                        $backups = Get-AzNetAppFilesVolumeBackup -ResourceGroupName $ResourceGroupName -AccountName $accountName -PoolName $poolName -VolumeName $volumeName -ErrorAction SilentlyContinue
                                        if ($backups) {
                                            $result.VolumeBackups += $backups
                                        }
                                    }
                                    catch {
                                        Write-Warning "  Error retrieving volume backups for $volumeName in pool ${poolName}: ${_}"
                                    }
                                }
                            }
                        }
                    }
                }
                
                # Get backup policies
                $backupPolicies = Get-AzNetAppFilesBackupPolicy -ResourceGroupName $ResourceGroupName -AccountName $accountName -ErrorAction SilentlyContinue
                if ($backupPolicies) {
                    $result.BackupPolicies += $backupPolicies
                }
                
                # Get backup vaults (if available)
                try {
                    # This command may not be available in all Az.NetAppFiles versions
                    $backupVaults = Get-AzNetAppFilesBackupVault -ResourceGroupName $ResourceGroupName -AccountName $accountName -ErrorAction SilentlyContinue
                    if ($backupVaults) {
                        $result.BackupVaults += $backupVaults
                    }
                }
                catch {
                    Write-Warning "  Error retrieving backup vaults for account $accountName (command may not be supported): ${_}"
                }
            }
            
            # Summary
            Write-Host "  Summary of NetApp resources found:" -ForegroundColor Yellow
            Write-Host "    Accounts: $($result.Accounts.Count)" -ForegroundColor Yellow
            Write-Host "    Capacity Pools: $($result.Pools.Count)" -ForegroundColor Yellow
            Write-Host "    Volumes: $($result.Volumes.Count)" -ForegroundColor Yellow
            Write-Host "    Snapshots: $($result.Snapshots.Count)" -ForegroundColor Yellow
            Write-Host "    Volume Backups: $($result.VolumeBackups.Count)" -ForegroundColor Yellow
            Write-Host "    Backup Policies: $($result.BackupPolicies.Count)" -ForegroundColor Yellow
            Write-Host "    Backup Vaults: $($result.BackupVaults.Count)" -ForegroundColor Yellow
            
            return $result
        }
        else {
            Write-Host "  No NetApp accounts found in resource group '$ResourceGroupName'" -ForegroundColor Green
            return $null
        }
    }
    catch {
        Write-Warning "  Error detecting NetApp resources: ${_}"
        return $null
    }
}

# Function to remove NetApp resources in the correct order
function Remove-NetAppResourcesSafely {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$NetAppResources
        
        
    )
    write-host "Removing NetApp resources..." -ForegroundColor Yellow

    # 1. remove the volumes
    foreach ($volume in $NetAppResources.Volumes) {
        #  $volume | Format-List * -Force | Out-String -Width 4096 | Write-Host -ForegroundColor Magenta
        
        #volumeName = ews_anf_uks/ews-anf-1tb/ews_vol_az1
        $accountName = $volume.Name.Split('/')[0]
        $poolName = $volume.Name.Split('/')[1]
        $volumeName = $volume.Name.Split('/')[2]
        
        if ($PSCmdlet.ShouldProcess($volumeName, "Remove NetApp Volume")) {
            try {
                Write-Host "  Removing volume '$volumeName' in pool '$poolName' of account '$accountName'" -ForegroundColor Yellow
                # write-host "Remove-AzNetAppFilesVolume -ResourceGroupName $ResourceGroupName -AccountName $accountName -PoolName $poolName -VolumeName $volumeName -Force"                
                Remove-AzNetAppFilesVolume -ResourceGroupName $ResourceGroupName -AccountName $accountName -PoolName $poolName -VolumeName $volumeName -Force
                Write-Host "  Successfully removed volume '$volumeName'" -ForegroundColor Green
            }
            catch {
                Write-Warning "  Error removing volume '$volumeName': ${_}"
            }
        }
    }

    # 2. remove the capacity pools
    foreach ($pool in $NetAppResources.Pools) {
        $accountName = $pool.Name.Split('/')[0]
        $poolName = $pool.Name.Split('/')[1]
        
        if ($PSCmdlet.ShouldProcess($poolName, "Remove NetApp Capacity Pool")) {
            try {
                Write-Host "  Removing capacity pool '$poolName' of account '$accountName'" -ForegroundColor Yellow
                #write-host "Remove-AzNetAppFilesPool -ResourceGroupName $ResourceGroupName -AccountName $accountName -PoolName $poolName"
                Remove-AzNetAppFilesPool -ResourceGroupName $ResourceGroupName -AccountName $accountName -PoolName $poolName
                Write-Host "  Successfully removed capacity pool '$poolName'" -ForegroundColor Green
            }
            catch {
                Write-Warning "  Error removing capacity pool '$poolName': ${_}"
            }
        }
    }

    # 3. remove the backup policies
    foreach ($policy in $NetAppResources.BackupPolicies) {
        $accountName = $policy.Name.Split('/')[0]
        $policyName = $policy.Name.Split('/')[1]
        
        if ($PSCmdlet.ShouldProcess($policyName, "Remove NetApp Backup Policy")) {
            try {
                Write-Host "  Removing backup policy '$policyName' of account '$accountName'" -ForegroundColor Yellow
                #write-host "Remove-AzNetAppFilesBackupPolicy -ResourceGroupName $ResourceGroupName -AccountName $accountName -BackupPolicyName $policyName"
                Remove-AzNetAppFilesBackupPolicy -ResourceGroupName $ResourceGroupName -AccountName $accountName -BackupPolicyName $policyName
                Write-Host "  Successfully removed backup policy '$policyName'" -ForegroundColor Green
            }
            catch {
                Write-Warning "  Error removing backup policy '$policyName': ${_}"
            }
        }
    }

    # 4.0 remove backup from backup vaults
    foreach ($backup in $NetAppResources.VolumeBackups) {

        
        
        
        $accountName = $backup.Name.Split('/')[0]
        $poolName = $backup.Name.Split('/')[1]
        $volumeName = $backup.Name.Split('/')[2]
        $backupName = $backup.Name.Split('/')[3]
        
        if ($PSCmdlet.ShouldProcess($backupName, "Remove NetApp Volume Backup")) {
            try {
                Write-Host "  Removing volume backup '$backupName' of volume '$volumeName' in pool '$poolName' of account '$accountName'" -ForegroundColor Yellow
                # This command may not be available in all Az.NetAppFiles versions
                write-host "Remove-AzNetAppFilesVolumeBackup -ResourceGroupName $ResourceGroupName -AccountName $accountName -PoolName $poolName -VolumeName $volumeName -BackupName $backupName -Force"
                Remove-AzNetAppFilesVolumeBackup -ResourceGroupName $ResourceGroupName -AccountName $accountName -PoolName $poolName -VolumeName $volumeName -BackupName $backupName -Force
                Write-Host "  Successfully removed volume backup '$backupName'" -ForegroundColor Green
            }
            catch {
                Write-Warning "  Error removing volume backup '$backupName' (command may not be supported): ${_}"
            }
        }
    }
    # 4. remove the backup vaults
    foreach ($vault in $NetAppResources.BackupVaults) {
        #$vault | Format-List * -Force | Out-String -Width 4096 | Write-Host -ForegroundColor Magenta
        $accountName = $vault.Name.Split('/')[0]
        $vaultName = $vault.Name.Split('/')[1]

        # query all backup in the vault and remove them first
        try {
            # This command may not be available in all Az.NetAppFiles versions
            $backupsInVault = Get-AzNetAppFilesBackup -ResourceGroupName $ResourceGroupName -AccountName $accountName -BackupVaultName $vaultName -ErrorAction SilentlyContinue
            if ($backupsInVault) {
                foreach ($backup in $backupsInVault) {
                    $backupName = $backup.Name.Split('/')[-1]
                    if ($PSCmdlet.ShouldProcess($backupName, "Remove NetApp Backup in Vault")) {
                        try {
                            Write-Host "  Removing backup '$backupName' in vault '$vaultName' of account '$accountName'" -ForegroundColor Yellow
                            # This command may not be available in all Az.NetAppFiles versions
                            #write-host "Remove-AzNetAppFilesBackup -ResourceGroupName $ResourceGroupName -AccountName $accountName -BackupVaultName $vaultName -BackupName $backupName"
                            Remove-AzNetAppFilesBackup -ResourceGroupName $ResourceGroupName -AccountName $accountName -BackupVaultName $vaultName -BackupName $backupName
                            Write-Host "  Successfully removed backup '$backupName'" -ForegroundColor Green
                        }
                        catch {
                            Write-Warning "  Error removing backup '$backupName' (command may not be supported): ${_}"
                        }
                    }
                }
            }
        }
        catch {
            Write-Warning "  Error retrieving backups in vault '$vaultName' (command may not be supported): ${_}"
        }

        # Now remove the vault
        if ($PSCmdlet.ShouldProcess($vaultName, "Remove NetApp Backup Vault")) {
            try {
                Write-Host "  Removing backup vault '$vaultName' of account '$accountName'" -ForegroundColor Yellow
                # This command may not be available in all Az.NetAppFiles versions
                write-host "Remove-AzNetAppFilesBackupVault -ResourceGroupName $ResourceGroupName -AccountName $accountName -BackupVaultName $vaultName"
                Remove-AzNetAppFilesBackupVault -ResourceGroupName $ResourceGroupName -AccountName $accountName -BackupVaultName $vaultName
                Write-Host "  Successfully removed backup vault '$vaultName'" -ForegroundColor Green
            }
            catch {
                Write-Warning "  Error removing backup vault '$vaultName' (command may not be supported): ${_}"
            }
        }
    }

    # 5. remove the NetApp accounts
    foreach ($account in $NetAppResources.Accounts) {
        $account | Format-List * -Force | Out-String -Width 4096 | Write-Host -ForegroundColor Magenta
        $accountName = $account.Name
        
        if ($PSCmdlet.ShouldProcess($accountName, "Remove NetApp Account")) {
            try {
                Write-Host "  Removing NetApp account '$accountName'" -ForegroundColor Yellow
                #write-host "Remove-AzNetAppFilesAccount -ResourceGroupName $ResourceGroupName -AccountName $accountName"
                Remove-AzNetAppFilesAccount -ResourceGroupName $ResourceGroupName -AccountName $accountName 
                Write-Host "  Successfully removed NetApp account '$accountName'" -ForegroundColor Green
            }
            catch {
                Write-Warning "  Error removing NetApp account '$accountName': ${_}"
            }
        }
    }

    exit 0

}
# Main script execution
Write-Host "Starting cleanup of NetApp resources in resource group: $ResourceGroupName" -ForegroundColor Cyan
#Write-Host "NETAPP Cleanup is not implemented yet, please cleanup manually." -ForegroundColor Red
try {
    # 1. Get all NetApp resources in the resource group
    Write-Host "Identifying NetApp resources..." -ForegroundColor Yellow
    $netAppResources = Get-NetAppResourcesInResourceGroup -ResourceGroupName $ResourceGroupName
    Write-Host "Removing NetApp resources..." -ForegroundColor Yellow
    Remove-NetAppResourcesSafely -NetAppResources $netAppResources     
    Write-Host "NetApp cleanup completed." -ForegroundColor Cyan
}
catch {
    Write-Error "Error during NetApp resource cleanup: ${_}"
}