<#
.SYNOPSIS
    Generates delta ADMX/ADML files containing only policies added between two Chrome ADMX versions.

.DESCRIPTION
    Compares a baseline and newer Chrome ADMX to identify new policies, then produces
    Intune-compatible ADMX/ADML files with versioned namespaces and filenames.

.PARAMETER BaselineAdmxPath
    Path to the baseline (older) chrome.admx file.

.PARAMETER NewerAdmxPath
    Path to the newer chrome.admx file.

.PARAMETER OutputFolder
    Folder where the delta ADMX and ADML files will be written.

.PARAMETER BaselineVersion
    Short version label for the baseline (e.g. "141").

.PARAMETER NewerVersion
    Short version label for the newer version (e.g. "143").

.EXAMPLE
    .\Compare-ADMXPolicies.ps1 `
        -BaselineAdmxPath ".\GoogleChromeADMx\policy_templates_141\windows\admx\chrome.admx" `
        -NewerAdmxPath    ".\GoogleChromeADMx\policy_templates_143\windows\admx\chrome.admx" `
        -OutputFolder     ".\IntuneADMX" `
        -BaselineVersion  "141" `
        -NewerVersion     "143"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaselineAdmxPath,
    [Parameter(Mandatory)][string]$NewerAdmxPath,
    [Parameter(Mandatory)][string]$OutputFolder,
    [Parameter(Mandatory)][string]$BaselineVersion,
    [Parameter(Mandatory)][string]$NewerVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helper Functions

function Get-PolicyNames {
    <#
    .SYNOPSIS Returns a set of policy name attributes from an ADMX XML document.
    #>
    param([xml]$AdmxXml)
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($policy in $AdmxXml.policyDefinitions.policies.policy) {
        [void]$names.Add($policy.name)
    }
    return $names
}

function Get-CategoryNames {
    <#
    .SYNOPSIS Returns a set of category name attributes from an ADMX XML document.
    #>
    param([xml]$AdmxXml)
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($cat in $AdmxXml.policyDefinitions.categories.category) {
        [void]$names.Add($cat.name)
    }
    return $names
}

function Get-ReferencedStringIds {
    <#
    .SYNOPSIS Extracts all $(string.XXX) references from an XML fragment string.
    #>
    param([string]$XmlText)
    $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $regex = [regex]::new('\$\(string\.([^)]+)\)')
    foreach ($m in $regex.Matches($XmlText)) {
        [void]$ids.Add($m.Groups[1].Value)
    }
    return $ids
}

function Get-ReferencedPresentationIds {
    <#
    .SYNOPSIS Extracts all $(presentation.XXX) references from an XML fragment string.
    #>
    param([string]$XmlText)
    $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $regex = [regex]::new('\$\(presentation\.([^)]+)\)')
    foreach ($m in $regex.Matches($XmlText)) {
        [void]$ids.Add($m.Groups[1].Value)
    }
    return $ids
}

function Resolve-CategoryChain {
    <#
    .SYNOPSIS Walks up the category tree to collect all ancestor categories needed.
    #>
    param(
        [System.Collections.Generic.HashSet[string]]$DirectCategories,
        [xml]$AdmxXml
    )
    $all = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $catLookup = @{}
    foreach ($cat in $AdmxXml.policyDefinitions.categories.category) {
        $catLookup[$cat.name] = $cat
    }

    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($name in $DirectCategories) { $queue.Enqueue($name) }

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $all.Add($current)) { continue }
        if ($catLookup.ContainsKey($current)) {
            $parentRef = $catLookup[$current].parentCategory
            if ($parentRef -and $parentRef.ref) {
                $ref = $parentRef.ref
                # Skip cross-namespace refs like "Google:Cat_Google"
                if ($ref -notmatch ':') {
                    $queue.Enqueue($ref)
                }
            }
        }
    }
    return $all
}

#endregion

#region Main Logic

Write-Host "`n=== ADMxSquizer - Delta ADMX Generator ===" -ForegroundColor Cyan
Write-Host "Baseline: v$BaselineVersion ($BaselineAdmxPath)"
Write-Host "Newer:    v$NewerVersion ($NewerAdmxPath)`n"

# --- Load ADMX files ---
[xml]$baselineXml = Get-Content -Path $BaselineAdmxPath -Raw -Encoding UTF8
[xml]$newerXml    = Get-Content -Path $NewerAdmxPath    -Raw -Encoding UTF8

# --- Extract version comment from newer ADMX ---
$newerRaw = Get-Content -Path $NewerAdmxPath -Raw -Encoding UTF8
$versionMatch = [regex]::Match($newerRaw, '<!--chrome version:\s*([^>]+?)-->')
$fullVersion = if ($versionMatch.Success) { $versionMatch.Groups[1].Value.Trim() } else { $NewerVersion }

# --- Identify delta policies ---
$baselinePolicyNames = Get-PolicyNames -AdmxXml $baselineXml
$newerPolicyNames    = Get-PolicyNames -AdmxXml $newerXml

$deltaPolicies = @()
foreach ($policy in $newerXml.policyDefinitions.policies.policy) {
    if (-not $baselinePolicyNames.Contains($policy.name)) {
        $deltaPolicies += $policy
    }
}

Write-Host "Policies in baseline (v$BaselineVersion): $($baselinePolicyNames.Count)" -ForegroundColor Gray
Write-Host "Policies in newer    (v$NewerVersion):    $($newerPolicyNames.Count)" -ForegroundColor Gray
Write-Host "Delta policies (new in v$NewerVersion):   $($deltaPolicies.Count)" -ForegroundColor Green

if ($deltaPolicies.Count -eq 0) {
    Write-Host "`nNo new policies found. Skipping output generation." -ForegroundColor Yellow
    return
}

# --- Collect all string and presentation IDs referenced by delta policies ---
$allStringIds       = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$allPresentationIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$directCategories   = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

foreach ($policy in $deltaPolicies) {
    $policyXml = $policy.OuterXml
    foreach ($id in (Get-ReferencedStringIds -XmlText $policyXml)) {
        [void]$allStringIds.Add($id)
    }
    foreach ($id in (Get-ReferencedPresentationIds -XmlText $policyXml)) {
        [void]$allPresentationIds.Add($id)
    }
    # Collect direct category references
    if ($policy.parentCategory -and $policy.parentCategory.ref) {
        [void]$directCategories.Add($policy.parentCategory.ref)
    }
}

# --- Resolve full category chain and collect category string references ---
$baselineCategoryNames = Get-CategoryNames -AdmxXml $baselineXml
$allNeededCategories = Resolve-CategoryChain -DirectCategories $directCategories -AdmxXml $newerXml

# Collect string IDs from category displayName attributes
foreach ($cat in $newerXml.policyDefinitions.categories.category) {
    if ($allNeededCategories.Contains($cat.name)) {
        foreach ($id in (Get-ReferencedStringIds -XmlText $cat.OuterXml)) {
            [void]$allStringIds.Add($id)
        }
    }
}

# Also include supportedOn string IDs (SUPPORTED_WIN7 etc.)
foreach ($def in $newerXml.policyDefinitions.supportedOn.definitions.definition) {
    foreach ($id in (Get-ReferencedStringIds -XmlText $def.OuterXml)) {
        [void]$allStringIds.Add($id)
    }
}

Write-Host "Referenced string IDs:       $($allStringIds.Count)" -ForegroundColor Gray
Write-Host "Referenced presentation IDs:  $($allPresentationIds.Count)" -ForegroundColor Gray
Write-Host "Categories needed:            $($allNeededCategories.Count)" -ForegroundColor Gray

# --- Build output ADMX ---
$deltaLabel = "chrome_v${NewerVersion}_delta_from_v${BaselineVersion}"
$versionedNamespace = "Google.Policies.Chrome.v${NewerVersion}"

$admxBuilder = [System.Text.StringBuilder]::new()
[void]$admxBuilder.AppendLine('<?xml version="1.0" ?>')
[void]$admxBuilder.AppendLine('<policyDefinitions revision="1.0" schemaVersion="1.0">')
[void]$admxBuilder.AppendLine("  <!--chrome version: $fullVersion-->")
[void]$admxBuilder.AppendLine("  <!--delta: policies added in v$NewerVersion vs v$BaselineVersion-->")
[void]$admxBuilder.AppendLine('  <policyNamespaces>')
[void]$admxBuilder.AppendLine("    <target namespace=`"$versionedNamespace`" prefix=`"chrome`"/>")
[void]$admxBuilder.AppendLine('    <using namespace="Google.Policies" prefix="Google"/>')
[void]$admxBuilder.AppendLine('    <using namespace="Microsoft.Policies.Windows" prefix="windows"/>')
[void]$admxBuilder.AppendLine('  </policyNamespaces>')
[void]$admxBuilder.AppendLine('  <resources minRequiredRevision="1.0"/>')

# SupportedOn definitions
[void]$admxBuilder.AppendLine('  <supportedOn>')
[void]$admxBuilder.AppendLine('    <definitions>')
foreach ($def in $newerXml.policyDefinitions.supportedOn.definitions.definition) {
    [void]$admxBuilder.AppendLine("      $($def.OuterXml)")
}
[void]$admxBuilder.AppendLine('    </definitions>')
[void]$admxBuilder.AppendLine('  </supportedOn>')

# Categories (only those referenced by delta policies)
[void]$admxBuilder.AppendLine('  <categories>')
foreach ($cat in $newerXml.policyDefinitions.categories.category) {
    if ($allNeededCategories.Contains($cat.name)) {
        [void]$admxBuilder.AppendLine("    $($cat.OuterXml)")
    }
}
[void]$admxBuilder.AppendLine('  </categories>')

# Policies
[void]$admxBuilder.AppendLine('  <policies>')
foreach ($policy in $deltaPolicies) {
    [void]$admxBuilder.AppendLine("    $($policy.OuterXml)")
}
[void]$admxBuilder.AppendLine('  </policies>')
[void]$admxBuilder.AppendLine('</policyDefinitions>')

# --- Write output ADMX ---
$outputSubFolder = Join-Path $OutputFolder $deltaLabel
if (-not (Test-Path $outputSubFolder)) {
    New-Item -ItemType Directory -Path $outputSubFolder -Force | Out-Null
}

$admxOutputPath = Join-Path $outputSubFolder "$deltaLabel.admx"
$admxBuilder.ToString() | Out-File -FilePath $admxOutputPath -Encoding UTF8 -NoNewline
Write-Host "`nADMX written: $admxOutputPath" -ForegroundColor Green

# --- Process ADML files for each shared language ---
$baselineAdmxDir = Split-Path $BaselineAdmxPath -Parent
$newerAdmxDir    = Split-Path $NewerAdmxPath -Parent

$baselineLangs = Get-ChildItem -Path $baselineAdmxDir -Directory | Where-Object {
    Test-Path (Join-Path $_.FullName 'chrome.adml')
} | ForEach-Object { $_.Name }

$newerLangs = Get-ChildItem -Path $newerAdmxDir -Directory | Where-Object {
    Test-Path (Join-Path $_.FullName 'chrome.adml')
} | ForEach-Object { $_.Name }

# Use intersection of languages
$commonLangs = $baselineLangs | Where-Object { $newerLangs -contains $_ }

Write-Host "`nProcessing ADML for $($commonLangs.Count) languages..." -ForegroundColor Cyan

foreach ($lang in $commonLangs) {
    $newerAdmlPath = Join-Path $newerAdmxDir (Join-Path $lang 'chrome.adml')
    [xml]$admlXml = Get-Content -Path $newerAdmlPath -Raw -Encoding UTF8

    # Filter strings
    $filteredStrings = @()
    foreach ($str in $admlXml.policyDefinitionResources.resources.stringTable.string) {
        if ($allStringIds.Contains($str.id)) {
            $filteredStrings += $str
        }
    }

    # Filter presentations
    $filteredPresentations = @()
    if ($admlXml.policyDefinitionResources.resources.presentationTable) {
        foreach ($pres in $admlXml.policyDefinitionResources.resources.presentationTable.presentation) {
            if ($allPresentationIds.Contains($pres.id)) {
                $filteredPresentations += $pres
            }
        }
    }

    # Build ADML
    $admlBuilder = [System.Text.StringBuilder]::new()
    [void]$admlBuilder.AppendLine('<?xml version="1.0" ?>')
    [void]$admlBuilder.AppendLine('<policyDefinitionResources revision="1.0" schemaVersion="1.0">')
    [void]$admlBuilder.AppendLine("  <!--chrome version: $fullVersion-->")
    [void]$admlBuilder.AppendLine("  <!--delta: policies added in v$NewerVersion vs v$BaselineVersion-->")
    [void]$admlBuilder.AppendLine('  <displayName/>')
    [void]$admlBuilder.AppendLine('  <description/>')
    [void]$admlBuilder.AppendLine('  <resources>')
    [void]$admlBuilder.AppendLine('    <stringTable>')
    foreach ($str in $filteredStrings) {
        [void]$admlBuilder.AppendLine("      $($str.OuterXml)")
    }
    [void]$admlBuilder.AppendLine('    </stringTable>')
    [void]$admlBuilder.AppendLine('    <presentationTable>')
    foreach ($pres in $filteredPresentations) {
        [void]$admlBuilder.AppendLine("      $($pres.OuterXml)")
    }
    [void]$admlBuilder.AppendLine('    </presentationTable>')
    [void]$admlBuilder.AppendLine('  </resources>')
    [void]$admlBuilder.AppendLine('</policyDefinitionResources>')

    # Write ADML
    $langFolder = Join-Path $outputSubFolder $lang
    if (-not (Test-Path $langFolder)) {
        New-Item -ItemType Directory -Path $langFolder -Force | Out-Null
    }
    $admlOutputPath = Join-Path $langFolder "$deltaLabel.adml"
    $admlBuilder.ToString() | Out-File -FilePath $admlOutputPath -Encoding UTF8 -NoNewline

    Write-Host "  ADML written: $lang" -ForegroundColor DarkGray
}

# --- Summary ---
Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "Delta label:       $deltaLabel"
Write-Host "New policies:      $($deltaPolicies.Count)"
Write-Host "Languages:         $($commonLangs.Count)"
Write-Host "Output folder:     $outputSubFolder"
Write-Host "Delta policy names:"
foreach ($p in $deltaPolicies) {
    Write-Host "  - $($p.name)" -ForegroundColor White
}
Write-Host ""

#endregion
