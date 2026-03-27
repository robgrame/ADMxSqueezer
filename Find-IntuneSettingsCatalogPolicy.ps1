<#
.SYNOPSIS
    Checks if one or more Google Chrome policy names exist in the Intune Settings Catalog
    and shows the full catalog path.

.DESCRIPTION
    Given one or more Chrome policy names (as found on the Google Chrome Enterprise documentation),
    this script queries the Microsoft Graph API to determine whether each policy is available
    in the Intune Settings Catalog. When found, it displays the full Settings Catalog tree path
    (e.g. Google > Google Chrome > Local Network Access settings > PolicyName).

    Requires the Microsoft.Graph PowerShell SDK (Microsoft.Graph.Authentication module).

.PARAMETER PolicyNames
    One or more Chrome policy names to search for (e.g. "GeminiActOnWebSettings").

.EXAMPLE
    .\Find-IntuneSettingsCatalogPolicy.ps1 -PolicyNames "LocalNetworkAccessAllowedForUrls"

.EXAMPLE
    .\Find-IntuneSettingsCatalogPolicy.ps1 -PolicyNames "GeminiActOnWebSettings","SearchContentSharingSettings","ExtensionForceInstallWithNonMalwareViolationsEnabled"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$PolicyNames
)

$ErrorActionPreference = 'Stop'

# --- Authentication ---
function Connect-ToGraph {
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Error "Microsoft.Graph module not installed. Run: Install-Module Microsoft.Graph -Scope CurrentUser"
        return $false
    }
    $context = Get-MgContext
    if (-not $context) {
        Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All" -NoWelcome
    }
    return $true
}

# --- Category path resolution via keywords ---
function Get-CatalogPathFromKeywords {
    param([array]$Keywords, [string]$PolicyName)

    # Keywords contain entries like "\\Google\\Google Chrome\\Local Network Access settings"
    $pathEntry = $Keywords | Where-Object {
        $_ -match '^\\' -and $_ -notmatch '^Software\\' -and $_ -match '\\'
    } | Select-Object -First 1

    if ($pathEntry) {
        $cleanPath = $pathEntry.TrimStart('\').Replace('\', ' > ')
        return "$cleanPath > $PolicyName"
    }
    return $null
}

# --- Category path resolution via API (fallback) ---
$script:categoryCache = @{}

function Get-CategoryPath {
    param([string]$CategoryId)

    if (-not $CategoryId) { return $null }

    $segments = @()
    $currentId = $CategoryId

    while ($currentId) {
        if ($script:categoryCache.ContainsKey($currentId)) {
            $cat = $script:categoryCache[$currentId]
        }
        else {
            try {
                $uri = "https://graph.microsoft.com/beta/deviceManagement/configurationCategories/$currentId"
                $cat = Invoke-MgGraphRequest -Method GET -Uri $uri
                $script:categoryCache[$currentId] = $cat
            }
            catch {
                Write-Verbose "Could not resolve category $currentId : $_"
                break
            }
        }
        $segments = @($cat.displayName) + $segments
        $currentId = $cat.parentCategoryId
    }

    if ($segments.Count -gt 0) {
        return $segments -join ' > '
    }
    return $null
}

# --- Search for a Chrome policy in the Settings Catalog ---
function Search-SettingsCatalog {
    param([string]$PolicyName)

    $graphBaseUrl = "https://graph.microsoft.com/beta/deviceManagement"
    $uri = "$graphBaseUrl/configurationSettings?`$filter=contains(name,'$PolicyName')&`$top=50"

    try {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri
    }
    catch {
        Write-Warning "API query failed for '$PolicyName': $_"
        return @()
    }

    if (-not $response.value -or $response.value.Count -eq 0) {
        return @()
    }

    # Filter: exact name match, Chrome only (not Edge/MAM), root definitions only
    $chromeResults = $response.value | Where-Object {
        $_.name -eq $PolicyName -and
        ($_.id -match 'googlechrome' -or ($_.keywords -and ($_.keywords -join ' ') -match 'Google Chrome'))
    }

    return $chromeResults
}

# --- Main ---
Write-Host "`n🔍 Intune Settings Catalog - Chrome Policy Lookup" -ForegroundColor Green
Write-Host ("=" * 55) -ForegroundColor Green

Write-Host "`nConnecting to Microsoft Graph..." -ForegroundColor Yellow
if (-not (Connect-ToGraph)) { exit 1 }
Write-Host "✅ Connected`n" -ForegroundColor Green

$results = @()

foreach ($policyName in $PolicyNames) {
    Write-Host "🔎 $policyName" -ForegroundColor Cyan

    $found = Search-SettingsCatalog -PolicyName $policyName

    if ($found -and @($found).Count -gt 0) {
        foreach ($setting in @($found)) {
            # Resolve catalog path (keywords first, API fallback)
            $catalogPath = $null
            if ($setting.keywords) {
                $catalogPath = Get-CatalogPathFromKeywords -Keywords $setting.keywords -PolicyName $policyName
            }
            if (-not $catalogPath -and $setting.categoryId) {
                $catPath = Get-CategoryPath -CategoryId $setting.categoryId
                if ($catPath) { $catalogPath = "$catPath > $policyName" }
            }
            if (-not $catalogPath) { $catalogPath = $policyName }

            $platform = if ($setting.applicability.platform) { $setting.applicability.platform } else { "N/A" }
            $tech = if ($setting.applicability.technologies) { $setting.applicability.technologies } else { "N/A" }

            Write-Host "   ✅ Found in Settings Catalog" -ForegroundColor Green
            Write-Host "   📂 $catalogPath" -ForegroundColor White
            Write-Host "   📄 $($setting.displayName)" -ForegroundColor Gray
            Write-Host "   💻 Platform: $platform | Technology: $tech" -ForegroundColor Gray
            Write-Host ""

            $results += [PSCustomObject]@{
                PolicyName  = $policyName
                Status      = "Found"
                CatalogPath = $catalogPath
                DisplayName = $setting.displayName
                Platform    = $platform
                Technology  = $tech
                SettingId   = $setting.id
            }
        }
    }
    else {
        Write-Host "   ❌ Not found — may require custom ADMX ingestion" -ForegroundColor Red
        Write-Host ""

        $results += [PSCustomObject]@{
            PolicyName  = $policyName
            Status      = "Not Found"
            CatalogPath = "N/A"
            DisplayName = "N/A"
            Platform    = "N/A"
            Technology  = "N/A"
            SettingId   = "N/A"
        }
    }
}

# Summary
Write-Host "📋 Summary" -ForegroundColor Green
Write-Host ("-" * 55)
$results | Format-Table -AutoSize -Wrap -Property PolicyName, Status, CatalogPath
