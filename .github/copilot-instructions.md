# Copilot Instructions for ADMxSquizer

## What this repo does

ADMxSquizer generates **delta ADMX/ADML files** for Microsoft Intune. Google Chrome ships ADMX templates containing ALL policies in every version. Intune rejects duplicates when uploading multiple versions, so this tool extracts only the **new policies** added between two Chrome versions and produces Intune-compatible ADMX/ADML files with versioned namespaces.

## Architecture

- `GoogleChromeADMx/policy_templates_{version}/windows/admx/` — Source Chrome ADMX/ADML files per version
- `IntuneADMX/chrome_v{new}_delta_from_v{old}/` — Generated delta output (ADMX + ADML per language)
- `Compare-ADMXPolicies.ps1` — Main script: parses ADMX XML, diffs policy names, generates delta files

## Running the script

```powershell
.\Compare-ADMXPolicies.ps1 `
    -BaselineAdmxPath ".\GoogleChromeADMx\policy_templates_141\windows\admx\chrome.admx" `
    -NewerAdmxPath    ".\GoogleChromeADMx\policy_templates_146\windows\admx\chrome.admx" `
    -OutputFolder     ".\IntuneADMX" `
    -BaselineVersion  "141" `
    -NewerVersion     "146"
```

## Key conventions

- Delta ADMX files use versioned namespaces (`Google.Policies.Chrome.v146`) to avoid Intune conflicts
- ADML files are generated for the **intersection** of languages available in both versions
- Only `chrome.admx` is diffed; `google.admx` is identical across versions and ignored
- Policy identity is determined by the `name` attribute on `<policy>` elements
