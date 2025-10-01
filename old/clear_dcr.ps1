# Set the necessary parameters
param (
    [string]$resourceGroupName,
    [string]$dataCollectionRuleName
)


# Confirm the details with the user
Write-Output "You are about to delete the Data Collection Rule '$dataCollectionRuleName' in Resource Group '$resourceGroupName'."
$confirmation = Read-Host "Type 'yes' to confirm"

if ($confirmation -eq 'yes') {
    try {
        # Check for any locks on the Data Collection Rule
        $locks = Get-AzResourceLock -ResourceGroupName $resourceGroupName -ResourceName $dataCollectionRuleName -ResourceType "Microsoft.Insights/dataCollectionRules" 

        # Remove the lock if it exists
        foreach ($lock in $locks) {
            Remove-AzResourceLock -LockId $lock.LockId -Force
            Write-Output "Removed lock '$($lock.Name)' on Data Collection Rule '$dataCollectionRuleName'."
        }

        # Validate the existence of the Data Collection Rule
        $dataCollectionRule = Get-AzDataCollectionRule -ResourceGroupName $resourceGroupName -Name $dataCollectionRuleName -ErrorAction Stop

        if ($null -ne $dataCollectionRule) {
            # Delete the Data Collection Rule
            Remove-AzDataCollectionRule -ResourceGroupName $resourceGroupName -Name $dataCollectionRuleName
            Write-Output "Data Collection Rule '$dataCollectionRuleName' in Resource Group '$resourceGroupName' has been deleted."
        }
        else {
            Write-Output "Data Collection Rule '$dataCollectionRuleName' does not exist in Resource Group '$resourceGroupName'."
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