# This script summarizes the number of resources in each Azure Resource Group.
# Ensure you are logged in to Azure CLI before running this script.

# Get all resource groups
$resourceGroups = az group list --query "[].name" -o tsv

# Initialize an array to store the summary
$summary = @()

foreach ($rg in $resourceGroups) {
    # Count the number of resources in the resource group
    
    $resourceCount = az resource list --resource-group $rg | ConvertFrom-Json

    if ($resourceCount.Count -eq 0) {
        Write-Host "Resource group $rg is empty." -ForegroundColor Red
        # Delete the empty resource group
        az group delete --name $rg --yes --no-wait
    }
    else {
        Write-Host "Resource group $rg has $($resourceCount.Count) resources." -ForegroundColor Yellow
    }
    # Add the result to the summary
    $summary += [PSCustomObject]@{
        ResourceGroup = $rg
        ResourceCount = $resourceCount.Count
    }
}

# Output the summary
$summary | Format-Table -AutoSize