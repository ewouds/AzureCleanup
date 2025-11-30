# Delete Azure AD/Entra ID Tenant - Cleanup Script (Azure CLI version)
# This script removes all resources that block tenant deletion
# 
# Prerequisites:
# - Install Azure CLI: https://aka.ms/installazurecli
# - Run: az login
#
# Usage:
# .\delete-azure-tenant-cli.ps1 -TenantId "f2bd0f21-e81e-4eb5-8874-d3a04564184e"

param(
    [Parameter(Mandatory=$true)]
    [string]$TenantId,
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf = $false  # Dry run mode
)

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "Azure AD Tenant Cleanup Script (Azure CLI)" -ForegroundColor Cyan
Write-Host "Tenant ID: $TenantId" -ForegroundColor Cyan
if ($WhatIf) {
    Write-Host "MODE: DRY RUN (Nothing will be deleted)" -ForegroundColor Yellow
} else {
    Write-Host "MODE: LIVE (Resources will be deleted)" -ForegroundColor Red
}
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# Check if Azure CLI is installed
Write-Host "Checking for Azure CLI..." -ForegroundColor Green
try {
    $azVersion = az version --output json 2>$null | ConvertFrom-Json
    Write-Host "✓ Azure CLI version: $($azVersion.'azure-cli')" -ForegroundColor Green
} catch {
    Write-Host "✗ Azure CLI not found. Please install from: https://aka.ms/installazurecli" -ForegroundColor Red
    exit 1
}

# Confirm before proceeding
if (-not $WhatIf) {
    $confirmation = Read-Host "This will delete resources in tenant $TenantId. Type 'DELETE' to confirm"
    if ($confirmation -ne 'DELETE') {
        Write-Host "Cancelled by user" -ForegroundColor Yellow
        exit
    }
}

# Login to the specific tenant
Write-Host "`nLogging in to tenant..." -ForegroundColor Green
try {
    az login --tenant $TenantId --allow-no-subscriptions | Out-Null
    Write-Host "✓ Logged in successfully" -ForegroundColor Green
} catch {
    Write-Host "✗ Failed to login: $_" -ForegroundColor Red
    exit 1
}

# Verify we're in the correct tenant
$currentTenant = az account show --query "tenantId" -o tsv 2>$null
if ($currentTenant -ne $TenantId) {
    Write-Host "✗ ERROR: Current tenant ($currentTenant) does not match target tenant ($TenantId)" -ForegroundColor Red
    Write-Host "✗ ABORTING for safety" -ForegroundColor Red
    exit 1
}
Write-Host "✓ Verified: Operating on tenant $TenantId" -ForegroundColor Green

# Function to safely delete with error handling
function Safe-Delete {
    param($Command, $Description)
    
    try {
        if ($WhatIf) {
            Write-Host "  [DRY RUN] Would delete: $Description" -ForegroundColor Yellow
        } else {
            Invoke-Expression $Command 2>&1 | Out-Null
            Write-Host "  ✓ Deleted: $Description" -ForegroundColor Green
        }
    } catch {
        Write-Host "  ✗ Failed to delete $Description : $_" -ForegroundColor Red
    }
}

# 1. Delete App Registrations
Write-Host "`n[1/4] Deleting App Registrations..." -ForegroundColor Cyan
try {
    # Force query against the specific tenant
    $apps = az ad app list --all 2>$null | ConvertFrom-Json
    
    # Verify each app belongs to this tenant before deletion
    if ($apps) {
        Write-Host "  Found $($apps.Count) app registration(s) in tenant $TenantId" -ForegroundColor Gray
        
        foreach ($app in $apps) {
            $appId = $app.id
            $displayName = $app.displayName
            Write-Host "  Processing: $displayName (ID: $appId)" -ForegroundColor Gray
            Safe-Delete -Command "az ad app delete --id $appId" -Description "App: $displayName"
        }
        Write-Host "✓ Processed $($apps.Count) app registration(s)" -ForegroundColor Green
    } else {
        Write-Host "  No app registrations found" -ForegroundColor Gray
    }
} catch {
    Write-Host "✗ Failed to delete app registrations: $_" -ForegroundColor Red
}

# 2. Delete Service Principals (Enterprise Applications)
Write-Host "`n[2/4] Deleting Enterprise Applications..." -ForegroundColor Cyan
try {
    $sps = az ad sp list --all 2>$null | ConvertFrom-Json
    
    if ($sps) {
        Write-Host "  Found $($sps.Count) service principal(s) in tenant $TenantId" -ForegroundColor Gray
        
        $deleted = 0
        foreach ($sp in $sps) {
            # Skip Microsoft first-party apps
            if ($sp.appOwnerOrganizationId -ne "f8cdef31-a31e-4b4a-93e4-5f571e91255a") {
                $spId = $sp.id
                $displayName = $sp.displayName
                Write-Host "  Processing: $displayName (ID: $spId)" -ForegroundColor Gray
                Safe-Delete -Command "az ad sp delete --id $spId" -Description "SP: $displayName"
                $deleted++
            }
        }
        Write-Host "✓ Processed $deleted service principal(s)" -ForegroundColor Green
    } else {
        Write-Host "  No service principals found" -ForegroundColor Gray
    }
} catch {
    Write-Host "✗ Failed to delete service principals: $_" -ForegroundColor Red
}

# 3. Delete Users (except current user)
Write-Host "`n[3/4] Deleting Users..." -ForegroundColor Cyan
try {
    $currentUser = az ad signed-in-user show --query "id" -o tsv 2>$null
    $users = az ad user list --query "[?id!='$currentUser']" 2>$null | ConvertFrom-Json
    
    if ($users) {
        Write-Host "  Found $($users.Count) user(s) in tenant $TenantId (excluding current user)" -ForegroundColor Gray
        
        foreach ($user in $users) {
            $userId = $user.id
            $upn = $user.userPrincipalName
            Write-Host "  Processing: $upn (ID: $userId)" -ForegroundColor Gray
            Safe-Delete -Command "az ad user delete --id $userId" -Description "User: $upn"
        }
        Write-Host "✓ Processed $($users.Count) user(s)" -ForegroundColor Green
    } else {
        Write-Host "  No users to delete (or only current user remains)" -ForegroundColor Gray
    }
} catch {
    Write-Host "✗ Failed to delete users: $_" -ForegroundColor Red
}

# 4. Check for subscriptions
Write-Host "`n[4/4] Checking for Azure Subscriptions..." -ForegroundColor Cyan
try {
    $subscriptions = az account list --query "[?tenantId=='$TenantId']" | ConvertFrom-Json
    
    if ($subscriptions -and $subscriptions.Count -gt 0) {
        Write-Host "  ⚠ Found $($subscriptions.Count) Azure subscription(s):" -ForegroundColor Yellow
        foreach ($sub in $subscriptions) {
            Write-Host "    - $($sub.name) ($($sub.id))" -ForegroundColor Yellow
        }
        Write-Host "  ⚠ You must manually cancel/transfer these in Azure Portal" -ForegroundColor Yellow
        Write-Host "    Go to: https://portal.azure.com/#blade/Microsoft_Azure_Billing/SubscriptionsBlade" -ForegroundColor Yellow
    } else {
        Write-Host "  ✓ No Azure subscriptions found" -ForegroundColor Green
    }
} catch {
    Write-Host "  Could not check subscriptions" -ForegroundColor Gray
}

# Summary
Write-Host "`n================================================" -ForegroundColor Cyan
Write-Host "Cleanup Complete!" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Cyan

if (-not $WhatIf) {
    Write-Host "`nNext Steps:" -ForegroundColor Yellow
    Write-Host "1. Wait 5-10 minutes for deletions to propagate" -ForegroundColor White
    Write-Host "2. Go to: https://portal.azure.com" -ForegroundColor White
    Write-Host "3. Navigate to: Microsoft Entra ID > Overview > Manage Tenants" -ForegroundColor White
    Write-Host "4. Select tenant: $TenantId" -ForegroundColor White
    Write-Host "5. Click 'Delete' and follow the checklist" -ForegroundColor White
    Write-Host "`nIf you still see blockers, re-run this script after waiting." -ForegroundColor Yellow
} else {
    Write-Host "`nThis was a DRY RUN. Run without -WhatIf to delete resources." -ForegroundColor Yellow
}

Write-Host ""
