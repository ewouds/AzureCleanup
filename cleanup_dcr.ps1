<#
.SYNOPSIS
    Safely removes Data Collection Rule (DCR) associations that could block resource group deletion.

.DESCRIPTION
    This script removes Data Collection Rule (DCR) associations from resources in an Azure resource group.
    DCR associations often create cross-resource group dependencies that can prevent resource group deletion.
    
    The script supports two methods for removing associations:
    - Azure CLI method (default, more reliable)
    - REST API method (fallback when CLI cannot be used)
    
    It handles various DCR association formats and automatically attempts multiple approaches
    if the initial removal attempt fails.

.PARAMETER ResourceGroupName
    Name of the resource group containing DCR associations to remove.

.PARAMETER UseCLI
    When specified (default is $true), the script will use Azure CLI commands to remove DCR associations.
    This is typically more reliable than using REST API.

.PARAMETER UseRESTAPI
    When specified (default is $false), the script will try to use REST API calls to remove DCR associations
    instead of Azure CLI commands. Only use this if the CLI method fails.

.PARAMETER NoWaitOnDelete
    When specified, DCR association deletions won't wait for completion confirmation.
    Useful when removing many associations simultaneously for speed.

.PARAMETER Force
    When specified, prompts are suppressed and the script proceeds with deletion without confirmation.

.PARAMETER PassThru
    When specified, returns $true or $false indicating success or failure.

.EXAMPLE
    .\cleanup_dcr.ps1 -ResourceGroupName "my-resource-group"
    Removes all DCR associations from resources in the specified resource group using Azure CLI.

.EXAMPLE
    .\cleanup_dcr.ps1 -ResourceGroupName "my-resource-group" -UseRESTAPI
    Removes all DCR associations using REST API instead of Azure CLI.

.EXAMPLE
    .\cleanup_dcr.ps1 -ResourceGroupName "my-resource-group" -NoWaitOnDelete
    Removes DCR associations without waiting for operation completion.

.EXAMPLE
    $success = .\cleanup_dcr.ps1 -ResourceGroupName "my-resource-group" -PassThru
    Returns a boolean value indicating success or failure.

.NOTES
    Requires PowerShell 7 or higher with the following modules:
    - Az.Resources (for resource management)
    - Az.Accounts (for authentication with REST API)
    
    Azure CLI is required for the default method.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false, Position = 0, HelpMessage = "Name of the resource group containing DCR associations to remove")]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $false)]
    [switch]$UseCLI = $true,
    
    [Parameter(Mandatory = $false)]
    [switch]$UseRESTAPI = $false,
    
    [Parameter(Mandatory = $false)]
    [switch]$NoWaitOnDelete = $false,
    
    [Parameter(Mandatory = $false)]
    [switch]$Force = $false,
    
    [Parameter(Mandatory = $false)]
    [switch]$PassThru = $false
)

# Function to check for required modules and versions
function Test-RequiredModules {
    # Verify Az.Resources module is installed and loaded
    $resourcesModule = Get-Module -Name Az.Resources -ListAvailable
    if (-not $resourcesModule) {
        Write-Warning "Az.Resources module not found. Installing module..."
        Install-Module -Name Az.Resources -Scope CurrentUser -Force
    }

    # Verify Az.Accounts module is installed and loaded
    $accountsModule = Get-Module -Name Az.Accounts -ListAvailable
    if (-not $accountsModule) {
        Write-Warning "Az.Accounts module not found. Installing module..."
        Install-Module -Name Az.Accounts -Scope CurrentUser -Force
    }

    # Import modules if not already loaded
    if (-not (Get-Module -Name Az.Resources)) {
        Import-Module -Name Az.Resources -ErrorAction Stop
    }
    if (-not (Get-Module -Name Az.Accounts)) {
        Import-Module -Name Az.Accounts -ErrorAction Stop
    }
}

# Function to remove DCR associations using Azure CLI
function Remove-DataCollectionRuleAssociationsCLI {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $false)]
        [switch]$NoWaitOnDelete = $false
    )
    
    try {
        Write-Host "  Using Azure CLI method for DCR associations..." -ForegroundColor Yellow
        
        # Check if Azure CLI is installed
        $azCliCheck = Get-Command az -ErrorAction SilentlyContinue
        if (-not $azCliCheck) {
            Write-Warning "  Azure CLI not found. Cannot use CLI method."
            return $false
        }
        
        # Ensure Azure CLI is logged in
        try {
            $account = az account show 2>$null | ConvertFrom-Json
            if (-not $account) {
                Write-Host "  Azure CLI not logged in. Attempting login..." -ForegroundColor Yellow
                az login --use-device-code
                if ($LASTEXITCODE -ne 0) {
                    throw "Azure CLI login failed"
                }
            }
        }
        catch {
            Write-Warning "  Failed to check Azure CLI login status: $_"
        }
        
        # Get all DCRs in the resource group using Azure CLI
        Write-Host "  Listing Data Collection Rules in resource group '$ResourceGroupName'..." -ForegroundColor Yellow
        $dcrJson = az resource list --resource-group $ResourceGroupName --resource-type "Microsoft.Insights/dataCollectionRules" --query "[].{name:name, id:id}" -o json
        
        if (-not $dcrJson -or $dcrJson -eq "[]") {
            Write-Host "  No Data Collection Rules found in resource group." -ForegroundColor Green
            return $true
        }
        
        $dcrs = $dcrJson | ConvertFrom-Json
        Write-Host "  Found $($dcrs.Count) Data Collection Rules." -ForegroundColor Yellow
        
        foreach ($dcr in $dcrs) {
            Write-Host "  Processing DCR: $($dcr.name)" -ForegroundColor Yellow
            
            # List associations using CLI with timeout and error handling
            Write-Host "  Listing associations..." -ForegroundColor Yellow
            try {
                # Parse the resource ID to get the rule name and resource group
                $idParts = $dcr.id -split '/'
                $resourceGroupIndex = [array]::IndexOf($idParts, 'resourceGroups')
                $resourceGroupName = $idParts[$resourceGroupIndex + 1]
                $ruleName = $dcr.name
                
                Write-Host "    Using rule name '$ruleName' in resource group '$resourceGroupName'" -ForegroundColor Gray
                
                # Create a script block to run the command with correct syntax
                $scriptBlock = {
                    param($rgName, $rName)
                    az monitor data-collection rule association list --rule-name $rName --resource-group $rgName -o json
                }
                
                # Start a job to run the command with a timeout
                $job = Start-Job -ScriptBlock $scriptBlock -ArgumentList $resourceGroupName, $ruleName
                
                # Wait for up to 60 seconds for the command to complete
                $completed = Wait-Job -Job $job -Timeout 60
                
                if ($completed -eq $null) {
                    Write-Warning "  Listing associations timed out after 60 seconds. Proceeding with next step."
                    Stop-Job -Job $job
                    Remove-Job -Job $job -Force
                    continue
                }
                
                $associationsJson = Receive-Job -Job $job
                Remove-Job -Job $job -Force
            }
            catch {
                Write-Warning "  Error listing associations: $_"
                continue
            }
            
            if (-not $associationsJson -or $associationsJson -eq "[]") {
                Write-Host "  No associations found for this DCR." -ForegroundColor Green
                continue
            }
            
            # Parse the JSON response, ensuring we handle both arrays and single objects properly
            $associations = $associationsJson | ConvertFrom-Json
            
            # Convert to array if it's not already
            if ($associations -and -not ($associations -is [array])) {
                $associations = @($associations)
            }
            
            Write-Host "  Found $($associations.Count) associations. Removing..." -ForegroundColor Yellow
            
            # Debug output to inspect association format
            if ($associations.Count -gt 0) {
                Write-Host "  First association sample:" -ForegroundColor Gray
                $firstAssoc = $associations[0]
                Write-Host "    $($firstAssoc | ConvertTo-Json -Depth 2)" -ForegroundColor Gray
            }
            
            foreach ($assoc in $associations) {
                try {
                    # Check for different formats of association response
                    if ($assoc.PSObject.Properties.Name -contains 'name') {
                        $assocName = $assoc.name
                    } elseif ($assoc.PSObject.Properties.Name -contains 'associationName') {
                        $assocName = $assoc.associationName
                    } else {
                        Write-Warning "    Could not determine association name from response. Skipping."
                        continue
                    }
                    
                    # Check for different property names for target resource
                    $targetResource = $null
                    
                    # Try to extract the target resource from the association ID
                    if ($assoc.PSObject.Properties.Name -contains 'id') {
                        # The format is typically:
                        # /subscriptions/{subId}/resourcegroups/{resourceGroup}/providers/{provider}/{resourceType}/{resourceName}/providers/Microsoft.Insights/dataCollectionRuleAssociations/{assocName}
                        $idParts = $assoc.id -split '/providers/microsoft.insights/datacollectionruleassociations/'
                        if ($idParts.Length -gt 0) {
                            $targetResource = $idParts[0]  # This gives us the target resource path
                            Write-Host "    Extracted target resource from ID: $targetResource" -ForegroundColor Gray
                        }
                    }
                    
                    # Fall back to other property names if the above extraction failed
                    if (-not $targetResource) {
                        if ($assoc.PSObject.Properties.Name -contains 'properties' -and 
                            $assoc.properties.PSObject.Properties.Name -contains 'targetResourceId') {
                            $targetResource = $assoc.properties.targetResourceId
                        } elseif ($assoc.PSObject.Properties.Name -contains 'targetResourceId') {
                            $targetResource = $assoc.targetResourceId
                        } elseif ($assoc.PSObject.Properties.Name -contains 'resourceUri') {
                            $targetResource = $assoc.resourceUri
                        }
                    }
                    
                    if (-not $targetResource) {
                        Write-Warning "    Could not determine target resource from association. Skipping."
                        continue
                    }
                    
                    # Clean up the resource ID if needed (remove trailing slash, etc.)
                    $targetResource = $targetResource.TrimEnd('/')
                    
                    Write-Host "    Removing association '$assocName' from $targetResource..." -ForegroundColor Yellow
                    
                    $noWaitParam = if ($NoWaitOnDelete) { " --no-wait" } else { "" }
                    $deleteCmd = "az monitor data-collection rule association delete --name '$assocName' --resource '$targetResource' --yes$noWaitParam"
                    Write-Host "    Executing: $deleteCmd" -ForegroundColor Gray
                    
                    # First check if monitor-control-service extension is installed
                    $monitorExtCheck = az extension list --query "[?name=='monitor-control-service']" -o json | ConvertFrom-Json
                    if (-not $monitorExtCheck -or $monitorExtCheck.Count -eq 0) {
                        Write-Host "    Installing required monitor-control-service extension..." -ForegroundColor Yellow
                        az extension add --name monitor-control-service --only-show-errors
                    }
                    
                    $deleteResult = Invoke-Expression $deleteCmd 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "    Association removed successfully." -ForegroundColor Green
                    } else {
                        Write-Warning "    Association deletion returned code $LASTEXITCODE"
                        if ($deleteResult) {
                            Write-Warning "    Output: $deleteResult"
                        }
                        
                        # Provide help for common errors
                        if ($deleteResult -match "unrecognized arguments") {
                            Write-Host "    The command syntax might be incorrect. Trying alternative approach..." -ForegroundColor Yellow
                            # Try an alternative approach using REST API
                            Write-Host "    Using REST API fallback method..." -ForegroundColor Yellow
                            $apiVersion = "2021-04-01"
                            $restUri = "$targetResource/providers/Microsoft.Insights/dataCollectionRuleAssociations/$assocName"
                            
                            # Remove leading slash if present
                            if ($restUri.StartsWith("/")) {
                                $restUri = $restUri.Substring(1)
                            }
                            
                            $altDeleteCmd = "az rest --method DELETE --uri 'https://management.azure.com/$restUri?api-version=$apiVersion'"
                            Write-Host "    Executing alternative: $altDeleteCmd" -ForegroundColor Gray
                            $restResult = Invoke-Expression $altDeleteCmd 2>&1
                            
                            if ($LASTEXITCODE -eq 0) {
                                Write-Host "    Association removed successfully using REST API." -ForegroundColor Green
                            } else {
                                Write-Warning "    REST API deletion failed with code $LASTEXITCODE"
                                Write-Warning "    Output: $restResult"
                                
                                # Try one more approach with direct resource ID
                                Write-Host "    Trying direct DCR association deletion approach..." -ForegroundColor Yellow
                                $directDeleteCmd = "az monitor data-collection rule association delete --name '$assocName' --rule-name '$ruleName' --resource-group '$resourceGroupName'"
                                Write-Host "    Executing: $directDeleteCmd" -ForegroundColor Gray
                                Invoke-Expression $directDeleteCmd
                                
                                # If that still fails, try to delete by direct ARM ID if available
                                if ($LASTEXITCODE -ne 0 -and $assoc.PSObject.Properties.Name -contains 'id') {
                                    Write-Host "    Trying deletion by ARM ID..." -ForegroundColor Yellow
                                    $armIdDeleteCmd = "az resource delete --ids '$($assoc.id)' --verbose"
                                    Write-Host "    Executing: $armIdDeleteCmd" -ForegroundColor Gray
                                    Invoke-Expression $armIdDeleteCmd
                                }
                            }
                        }
                    }
                }
                catch {
                    Write-Warning "    Failed to remove association: $_"
                }
            }
        }
        
        # Also check for Data Collection Endpoints
        Write-Host "  Checking for Data Collection Endpoints..." -ForegroundColor Yellow
        $dceJson = az resource list --resource-group $ResourceGroupName --resource-type "Microsoft.Insights/dataCollectionEndpoints" -o json
        
        if (-not $dceJson -or $dceJson -eq "[]") {
            Write-Host "  No Data Collection Endpoints found." -ForegroundColor Green
        }
        else {
            Write-Host "  Found Data Collection Endpoints. These are typically managed through DCRs." -ForegroundColor Yellow
        }
        
        return $true
    }
    catch {
        Write-Error "Error in CLI-based DCR association removal: $_"
        return $false
    }
}

# Function to remove DCR associations using REST API
function Remove-DataCollectionRuleAssociationsREST {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName
    )
    
    try {
        # Get all DCRs in the resource group
        Write-Host "  Checking for Data Collection Rules in resource group '$ResourceGroupName'..." -ForegroundColor Yellow
        $dcrs = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType "Microsoft.Insights/dataCollectionRules" -ErrorAction SilentlyContinue
        
        if ($dcrs) {
            Write-Host "  Found $($dcrs.Count) Data Collection Rules. Checking for associations..." -ForegroundColor Yellow
            
            # For each DCR, find and remove associations
            foreach ($dcr in $dcrs) {
                Write-Host "  Processing DCR: $($dcr.Name)" -ForegroundColor Yellow
                
                # List associations for this DCR (need to use REST API since Get-AzDataCollectionRuleAssociation doesn't filter by DCR)
                $associations = @()
                try {
                    # Get a new authorization token with explicit resource specification
                    try {
                        # First try with Az.Accounts cmdlets (newer method)
                        $token = (Get-AzAccessToken -ResourceTypeName "Arm").Token
                    }
                    catch {
                        # Fallback method - try multiple approaches to get a token
                        Write-Host "  Refreshing Azure auth context..." -ForegroundColor Yellow
                        try {
                            # Try with resource URL directly
                            $token = (Get-AzAccessToken -Resource "https://management.azure.com/").Token
                        }
                        catch {
                            try {
                                # Legacy fallback method
                                $azContext = Get-AzContext
                                $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
                                $profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList $azProfile
                                $token = $profileClient.AcquireAccessToken($azContext.Subscription.TenantId).AccessToken
                            }
                            catch {
                                Write-Warning "  Failed to get a valid token for API calls: $_"
                                continue
                            }
                        }
                    }
                    
                    $headers = @{
                        'Authorization' = "Bearer $token"
                        'Content-Type' = 'application/json'
                    }
                    
                    # Make REST API call to list associations for this DCR
                    $subscriptionId = (Get-AzContext).Subscription.Id
                    $dcrId = $dcr.ResourceId
                    $apiVersion = "2022-06-01"
                    $uri = "https://management.azure.com$dcrId/associations?api-version=$apiVersion"
                    
                    Write-Host "  Calling API: $uri" -ForegroundColor Yellow
                    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
                    if ($response.value) {
                        $associations = $response.value
                    }
                }
                catch {
                    Write-Warning "  Failed to get associations for DCR $($dcr.Name): $_"
                    continue
                }
                
                if ($associations.Count -gt 0) {
                    Write-Host "  Found $($associations.Count) associations for DCR $($dcr.Name)" -ForegroundColor Yellow
                    
                    foreach ($assoc in $associations) {
                        try {
                            $assocId = $assoc.id
                            $assocName = $assoc.name
                            $targetResourceId = $assoc.properties.targetResourceId
                            
                            Write-Host "    Removing association: $assocName from resource $targetResourceId" -ForegroundColor Yellow
                            
                            # Remove the association using REST API
                            $deleteUri = "https://management.azure.com$assocId`?api-version=$apiVersion"
                            Write-Host "    Calling delete API: $deleteUri" -ForegroundColor Yellow
                            # We might need to refresh the token for each delete operation
                            try {
                                # Try to get a fresh token
                                try {
                                    $deleteToken = (Get-AzAccessToken -ResourceTypeName "Arm").Token
                                }
                                catch {
                                    # Try fallback methods
                                    try {
                                        $deleteToken = (Get-AzAccessToken -Resource "https://management.azure.com/").Token
                                    }
                                    catch {
                                        # Last resort
                                        $azContext = Get-AzContext
                                        $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
                                        $profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList $azProfile
                                        $deleteToken = $profileClient.AcquireAccessToken($azContext.Subscription.TenantId).AccessToken
                                    }
                                }
                                
                                $deleteHeaders = @{
                                    'Authorization' = "Bearer $deleteToken"
                                    'Content-Type' = 'application/json'
                                }
                                Invoke-RestMethod -Uri $deleteUri -Headers $deleteHeaders -Method Delete -ErrorAction Stop
                            }
                            catch {
                                Write-Warning "    Error during delete request: $_"
                                throw
                            }
                            
                            Write-Host "    Association removed successfully" -ForegroundColor Green
                        }
                        catch {
                            Write-Warning "    Failed to remove association $($assoc.name): $_"
                        }
                    }
                }
                else {
                    Write-Host "  No associations found for DCR $($dcr.Name)" -ForegroundColor Green
                }
            }
        }
        else {
            Write-Host "  No Data Collection Rules found in resource group '$ResourceGroupName'" -ForegroundColor Green
        }
        
        # Also check for Data Collection Endpoints with associations
        $dces = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType "Microsoft.Insights/dataCollectionEndpoints" -ErrorAction SilentlyContinue
        if ($dces) {
            Write-Host "  Found $($dces.Count) Data Collection Endpoints. Checking for associations..." -ForegroundColor Yellow
            # Implementation similar to DCRs if needed
            # Currently DCE associations are typically managed through DCRs
        }
        
        return $true
    }
    catch {
        Write-Error "Error removing Data Collection Rule associations via REST API: $_"
        Write-Host "  Consider using Azure Portal to manually remove these associations or use the -UseCLI option." -ForegroundColor Yellow
        return $false
    }
}

# Function to remove DCR associations using the appropriate method
function Remove-DataCollectionRuleAssociations {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $false)]
        [switch]$UseCLIMethod = $true,
        
        [Parameter(Mandatory = $false)]
        [switch]$UseRESTMethod = $false,
        
        [Parameter(Mandatory = $false)]
        [switch]$NoWaitOnDelete = $false
    )
    
    try {
        # Check if we should use the CLI-based approach
        if ($UseCLIMethod -and (-not $UseRESTMethod)) {
            try {
                return Remove-DataCollectionRuleAssociationsCLI -ResourceGroupName $ResourceGroupName -NoWaitOnDelete:$NoWaitOnDelete
            }
            catch {
                Write-Warning "  Error in CLI-based DCR removal: $_. Trying fallback method."
                return Remove-DataCollectionRuleAssociationsREST -ResourceGroupName $ResourceGroupName
            }
        }
        
        # Use the REST approach
        if ($UseRESTMethod -or (-not $UseCLIMethod)) {
            return Remove-DataCollectionRuleAssociationsREST -ResourceGroupName $ResourceGroupName
        }
        
        # If we get here, use the default method
        return Remove-DataCollectionRuleAssociationsCLI -ResourceGroupName $ResourceGroupName -NoWaitOnDelete:$NoWaitOnDelete
    }
    catch {
        Write-Error "Error in DCR association removal: $_"
        return $false
    }
}

# Main script execution
try {
    # Display banner
    Write-Host "`n=== Azure Data Collection Rule Association Cleanup Script ===" -ForegroundColor Cyan
    
    # Verify required modules
    Test-RequiredModules
    
    # Check if we need to prompt for resource group name
    if (-not $ResourceGroupName) {
        if ($Force) {
            Write-Error "ResourceGroupName is required when Force is specified."
            if ($PassThru) { return $false } else { exit 1 }
        }
        
        # Prompt for resource group name
        $ResourceGroupName = Read-Host "Enter resource group name containing DCR associations to remove"
        if (-not $ResourceGroupName) {
            Write-Error "ResourceGroupName is required."
            if ($PassThru) { return $false } else { exit 1 }
        }
    }
    
    # Check if the resource group exists
    $resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $resourceGroup) {
        Write-Error "Resource group '$ResourceGroupName' not found."
        if ($PassThru) { return $false } else { exit 1 }
    }
    
    # Confirm action if Force is not specified
    if (-not $Force) {
        Write-Host "`nWARNING: This will remove all Data Collection Rule associations in resource group '$ResourceGroupName'." -ForegroundColor Yellow
        $confirm = Read-Host "Do you want to proceed? (y/n)"
        if ($confirm -ne "y") {
            Write-Host "Operation cancelled by user." -ForegroundColor Yellow
            if ($PassThru) { return $false } else { exit 0 }
        }
    }
    
    # Remove DCR associations using appropriate method
    Write-Host "`nRemoving Data Collection Rule associations from resource group '$ResourceGroupName'..." -ForegroundColor Yellow
    
    if ($UseCLI -and (-not $UseRESTAPI)) {
        $result = Remove-DataCollectionRuleAssociations -ResourceGroupName $ResourceGroupName -UseCLIMethod -NoWaitOnDelete:$NoWaitOnDelete
    }
    elseif ($UseRESTAPI -and (-not $UseCLI)) {
        $result = Remove-DataCollectionRuleAssociations -ResourceGroupName $ResourceGroupName -UseRESTMethod
    }
    else {
        # Default to CLI if neither or both are specified
        $result = Remove-DataCollectionRuleAssociations -ResourceGroupName $ResourceGroupName -UseCLIMethod -NoWaitOnDelete:$NoWaitOnDelete
    }
    
    if ($result) {
        Write-Host "`nSuccessfully processed DCR associations in resource group '$ResourceGroupName'." -ForegroundColor Green
        if ($PassThru) { return $true } else { exit 0 }
    }
    else {
        Write-Error "Failed to process DCR associations in resource group '$ResourceGroupName'."
        if ($PassThru) { return $false } else { exit 1 }
    }
}
catch {
    Write-Error "Unexpected error: $_"
    if ($PassThru) { return $false } else { exit 1 }
}