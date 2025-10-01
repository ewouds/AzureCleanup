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

# Function to format PSNetAppFilesVolume objects in human-readable format
function Format-NetAppVolume {
    <#
    .SYNOPSIS
        Formats a PSNetAppFilesVolume object in human-readable format.
    
    .DESCRIPTION
        Converts Microsoft.Azure.Commands.NetAppFiles.Models.PSNetAppFilesVolume objects
        into a formatted, easy-to-read display showing all important properties.
    
    .PARAMETER Volume
        The PSNetAppFilesVolume object to format.
    
    .EXAMPLE
        $volume = Get-AzNetAppFilesVolume -ResourceGroupName "myRG" -AccountName "myAccount" -PoolName "myPool" -Name "myVolume"
        Format-NetAppVolume -Volume $volume
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [Microsoft.Azure.Commands.NetAppFiles.Models.PSNetAppFilesVolume]$Volume
    )
    
    process {
        $output = @"

╔══════════════════════════════════════════════════════════════════════════════
║ NetApp Files Volume Details
╚══════════════════════════════════════════════════════════════════════════════

┌─ Basic Information ──────────────────────────────────────────────────────────
│ Name:                 $($Volume.Name)
│ Resource Group:       $($Volume.ResourceGroupName)
│ Location:             $($Volume.Location)
│ Resource ID:          $($Volume.Id)
│ Provisioning State:   $($Volume.ProvisioningState)
│ Creation Time:        $($Volume.CreationToken)
└──────────────────────────────────────────────────────────────────────────────

┌─ Hierarchy ──────────────────────────────────────────────────────────────────
│ NetApp Account:       $(($Volume.Id -split '/')[8])
│ Capacity Pool:        $(($Volume.Id -split '/')[10])
│ Volume Name:          $(($Volume.Id -split '/')[12])
└──────────────────────────────────────────────────────────────────────────────

┌─ Storage Configuration ──────────────────────────────────────────────────────
│ Usage (GB):           $([math]::Round($Volume.UsageThreshold / 1GB, 2)) GB
│ Service Level:        $($Volume.ServiceLevel)
│ Protocol Types:       $($Volume.ProtocolTypes -join ', ')
│ File Path:            $($Volume.CreationToken)
│ Subnet ID:            $($Volume.SubnetId)
└──────────────────────────────────────────────────────────────────────────────

┌─ Mount Information ──────────────────────────────────────────────────────────
│ Mount Targets:        $($Volume.MountTargets.Count)
"@

        if ($Volume.MountTargets -and $Volume.MountTargets.Count -gt 0) {
            foreach ($mt in $Volume.MountTargets) {
                $output += @"

│   • IP Address:       $($mt.IpAddress)
│     Mount Target ID:  $($mt.MountTargetId)
│     File System ID:   $($mt.FileSystemId)
"@
            }
        }
        
        $output += @"

└──────────────────────────────────────────────────────────────────────────────

┌─ Data Protection ────────────────────────────────────────────────────────────
"@

        if ($Volume.DataProtection) {
            if ($Volume.DataProtection.Backup) {
                $output += @"

│ Backup Enabled:       Yes
│   Backup Policy ID:   $($Volume.DataProtection.Backup.BackupPolicyId)
│   Policy Enforced:    $($Volume.DataProtection.Backup.PolicyEnforced)
│   Vault ID:           $($Volume.DataProtection.Backup.VaultId)
"@
            } else {
                $output += "`n│ Backup Enabled:       No"
            }
            
            if ($Volume.DataProtection.Replication) {
                $output += @"

│ Replication:          Yes
│   Remote Volume:      $($Volume.DataProtection.Replication.RemoteVolumeResourceId)
│   Replication Type:   $($Volume.DataProtection.Replication.ReplicationSchedule)
│   Endpoint Type:      $($Volume.DataProtection.Replication.EndpointType)
"@
            } else {
                $output += "`n│ Replication:          No"
            }
            
            if ($Volume.DataProtection.Snapshot) {
                $output += @"

│ Snapshot Policy:      Yes
│   Snapshot Policy ID: $($Volume.DataProtection.Snapshot.SnapshotPolicyId)
"@
            } else {
                $output += "`n│ Snapshot Policy:      No"
            }
        } else {
            $output += "`n│ Data Protection:      Not configured"
        }
        
        $output += @"

└──────────────────────────────────────────────────────────────────────────────

┌─ Export Policy ──────────────────────────────────────────────────────────────
"@

        if ($Volume.ExportPolicy -and $Volume.ExportPolicy.Rules -and $Volume.ExportPolicy.Rules.Count -gt 0) {
            $output += "`n│ Export Rules:         $($Volume.ExportPolicy.Rules.Count) rule(s)"
            $ruleNum = 1
            foreach ($rule in $Volume.ExportPolicy.Rules) {
                $output += @"

│
│ Rule ${ruleNum}:
│   Rule Index:         $($rule.RuleIndex)
│   Allowed Clients:    $($rule.AllowedClients)
│   Unix Read Only:     $($rule.UnixReadOnly)
│   Unix Read Write:    $($rule.UnixReadWrite)
│   Protocols:          $($rule.ProtocolTypes -join ', ')
│   Has Root Access:    $($rule.HasRootAccess)
"@
                $ruleNum++
            }
        } else {
            $output += "`n│ Export Rules:         None configured"
        }
        
        $output += @"

└──────────────────────────────────────────────────────────────────────────────

┌─ Security & Network ─────────────────────────────────────────────────────────
│ Security Style:       $($Volume.SecurityStyle)
│ SMB Encryption:       $($Volume.SmbEncryption)
│ SMB Continuously Avl: $($Volume.SmbContinuouslyAvailable)
│ Encryption Key Src:   $($Volume.EncryptionKeySource)
│ Network Features:     $($Volume.NetworkFeatures)
│ Network Sibling Set:  $($Volume.NetworkSiblingSetId)
└──────────────────────────────────────────────────────────────────────────────

┌─ Snapshot & Backup Information ──────────────────────────────────────────────
│ Snapshot Directory:   $($Volume.SnapshotDirectoryVisible)
│ Snapshot ID:          $($Volume.SnapshotId)
│ Backup Enabled:       $($Volume.BackupEnabled)
│ Backup ID:            $($Volume.BackupId)
└──────────────────────────────────────────────────────────────────────────────

┌─ Advanced Settings ──────────────────────────────────────────────────────────
│ Throughput (MiB/s):   $($Volume.ThroughputMibps)
│ Cool Access:          $($Volume.CoolAccess)
│ Coolness Period:      $($Volume.CoolnessPeriod) days
│ Unix Permissions:     $($Volume.UnixPermissions)
│ Avail Zone:           $($Volume.AvailabilityZone)
│ Capacity Pool Res:    $($Volume.CapacityPoolResourceId)
│ Cloning Progress:     $($Volume.CloneProgress)
│ Is Default Quota:     $($Volume.IsDefaultQuotaEnabled)
│ Default User Quota:   $($Volume.DefaultUserQuotaInKiBs) KiB
│ Default Group Quota:  $($Volume.DefaultGroupQuotaInKiBs) KiB
└──────────────────────────────────────────────────────────────────────────────

┌─ Tags ───────────────────────────────────────────────────────────────────────
"@

        if ($Volume.Tags -and $Volume.Tags.Count -gt 0) {
            foreach ($tag in $Volume.Tags.GetEnumerator()) {
                $output += "`n│ $($tag.Key): $($tag.Value)"
            }
        } else {
            $output += "`n│ No tags defined"
        }
        
        $output += @"

└──────────────────────────────────────────────────────────────────────────────

"@

        Write-Host $output -ForegroundColor Cyan
    }
}

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
                Accounts = $accounts
                Pools = @()
                Volumes = @()
                BackupPolicies = @()
                BackupVaults = @()
                Snapshots = @()
                VolumeBackups = @()
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
                                    } catch {
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
                } catch {
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
        } else {
            Write-Host "  No NetApp accounts found in resource group '$ResourceGroupName'" -ForegroundColor Green
            return $null
        }
    } catch {
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
    write-host $NetAppResources.Volumes

# 1. remove the volumes
    foreach ($volume in $NetAppResources.Volumes) {
        # write content of volume in humane readable format 
        write-host $volume
        $accountName = $volume.AccountName

        $poolName = $volume.PoolName
        $volumeName = $volume.Name
        
        if ($PSCmdlet.ShouldProcess($volumeName, "Remove NetApp Volume")) {
            try {
                Write-Host "  Removing volume '$volumeName' in pool '$poolName' of account '$accountName'" -ForegroundColor Yellow
                write-host "Remove-AzNetAppFilesVolume -ResourceGroupName $ResourceGroupName -AccountName $accountName -PoolName $poolName -VolumeName $volumeName -Force"
                exit 0
                Remove-AzNetAppFilesVolume -ResourceGroupName $ResourceGroupName -AccountName $accountName -PoolName $poolName -VolumeName $volumeName -Force
                Write-Host "  Successfully removed volume '$volumeName'" -ForegroundColor Green
            } catch {
                Write-Warning "  Error removing volume '$volumeName': ${_}"
            }
        }
    }
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
} catch {
    Write-Error "Error during NetApp resource cleanup: ${_}"
}