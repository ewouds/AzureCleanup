<#
.SYNOPSIS
    Updates Azure CLI extensions to resolve compatibility issues and warnings.

.DESCRIPTION
    This function checks for and updates Azure CLI extensions, with special handling
    for problematic extensions that may cause warnings or errors. It ensures that
    required extensions like monitor-control-service are properly installed and updated.

.PARAMETER FixProblematic
    When specified, the function will attempt to reinstall known problematic extensions
    such as containerapp to resolve import errors and warnings.

.EXAMPLE
    Update-AzureCliExtensions
    Updates all Azure CLI extensions with default behavior.

.EXAMPLE
    Update-AzureCliExtensions -FixProblematic
    Updates all extensions and reinstalls known problematic ones.

.OUTPUTS
    System.Boolean
    Returns $true if the update process completed successfully, $false otherwise.
#>
function Update-AzureCliExtensions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$FixProblematic = $false
    )
    
    try {
        # Check if Azure CLI is available
        $azCliCheck = Get-Command az -ErrorAction SilentlyContinue
        if (-not $azCliCheck) {
            Write-Warning "Azure CLI not found. Cannot update extensions."
            return $false
        }
        
        Write-Host "Checking Azure CLI version..." -ForegroundColor Yellow
        $azVersion = az version --json 2>$null | ConvertFrom-Json
        Write-Host "Azure CLI version: $($azVersion.'azure-cli')" -ForegroundColor Yellow
        
        # Make sure the monitor-control-service extension is installed
        Write-Host "Checking for monitor-control-service extension..." -ForegroundColor Yellow
        $monitorControlExtension = az extension list --query "[?name=='monitor-control-service']" -o json | ConvertFrom-Json
        
        if (-not $monitorControlExtension -or $monitorControlExtension.Count -eq 0) {
            Write-Host "Installing monitor-control-service extension..." -ForegroundColor Yellow
            az extension add --name monitor-control-service --only-show-errors
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Successfully installed monitor-control-service extension." -ForegroundColor Green
            }
            else {
                Write-Warning "Failed to install monitor-control-service extension. Some DCR operations may fail."
            }
        }
        else {
            Write-Host "monitor-control-service extension is already installed." -ForegroundColor Green
            
            # Update the extension
            Write-Host "Updating monitor-control-service extension..." -ForegroundColor Yellow
            az extension update --name monitor-control-service --only-show-errors
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Successfully updated monitor-control-service extension." -ForegroundColor Green
            }
        }
        
        # Check for outdated extensions
        Write-Host "Checking for outdated extensions..." -ForegroundColor Yellow
        $outdatedExtensions = az extension list-available --query "[?installed].{name:name}" -o json --only-show-errors 2>$null | ConvertFrom-Json
        
        # Check for problematic extensions
        if ($FixProblematic) {
            $problematicExtensions = @("containerapp")
            Write-Host "Checking for known problematic extensions..." -ForegroundColor Yellow
            $installedExtensions = az extension list --query "[].name" -o json --only-show-errors 2>$null | ConvertFrom-Json
            
            foreach ($extension in $problematicExtensions) {
                if ($installedExtensions -contains $extension) {
                    Write-Host "Found potentially problematic extension: $extension. Will attempt to reinstall it." -ForegroundColor Yellow
                    # First try to remove the extension
                    Write-Host "Removing $extension extension..." -ForegroundColor Yellow
                    az extension remove -n $extension --only-show-errors 2>$null
                    # Then add it back
                    Write-Host "Reinstalling $extension extension..." -ForegroundColor Yellow
                    az extension add -n $extension --only-show-errors 2>$null
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "Successfully reinstalled $extension extension." -ForegroundColor Green
                    }
                    else {
                        Write-Warning "Could not reinstall $extension extension. You may need to manually fix it."
                    }
                }
            }
        }
        
        if ($outdatedExtensions -and $outdatedExtensions.Count -gt 0) {
            Write-Host "Found potentially outdated extensions. Attempting to update all extensions..." -ForegroundColor Yellow
            
            # Update all extensions
            $updateResult = az extension update --all --only-show-errors 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Successfully updated all extensions." -ForegroundColor Green
            }
            else {
                Write-Warning "Some extensions could not be updated. Error code: $LASTEXITCODE"
                if ($updateResult) {
                    Write-Warning "Output: $($updateResult | Out-String)"
                }
                
                # Try to update the monitor extension specifically
                Write-Host "Attempting to update monitor extension specifically..." -ForegroundColor Yellow
                az extension update -n monitor --only-show-errors 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "Successfully updated monitor extension." -ForegroundColor Green
                }
                else {
                    Write-Warning "Could not update monitor extension. Error code: $LASTEXITCODE"
                    
                    # Try removing and reinstalling the monitor extension
                    Write-Host "Attempting to reinstall monitor extension..." -ForegroundColor Yellow
                    az extension remove -n monitor --only-show-errors 2>$null
                    az extension add -n monitor --only-show-errors 2>$null
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "Successfully reinstalled monitor extension." -ForegroundColor Green
                    }
                    else {
                        Write-Warning "Could not reinstall monitor extension."
                    }
                }
            }
        }
        else {
            Write-Host "No outdated extensions found." -ForegroundColor Green
        }
        
        return $true
    }
    catch {
        Write-Warning "Error updating Azure CLI extensions: $_"
        return $false
    }
}