# 🔧 ADMxSquizer

> **Deduplicate Chrome ADMX policies for clean Intune uploads across multiple Chrome versions.**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell&logoColor=white)](https://docs.microsoft.com/powershell/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows-0078D6?logo=windows)](https://www.microsoft.com/windows)

---

## 📋 The Problem

Microsoft Intune allows administrators to upload **ADMX files** to manage Group Policy settings on enrolled devices. However, it has critical limitations when dealing with **multiple versions** of the same ADMX template:

| ❌ Limitation | Description |
|---|---|
| **Duplicate rejection** | Intune blocks uploading an ADMX file with the same namespace, even if it's from a different Chrome version |
| **Policy duplication** | Renaming the file to bypass the check results in the **same policies appearing multiple times** in the Settings Catalog — once per imported ADMX |
| **No built-in versioning** | Google ships every Chrome ADMX with **all policies** included, with no mechanism to import only what's new |

### 🎯 The Impact

For organizations managing Chrome across thousands of endpoints, this means:

- 🚫 **Unable to adopt new Chrome policies** without removing old ADMX imports first
- 📑 **Cluttered Settings Catalog** with hundreds of duplicate policy entries
- ⚠️ **Risk of misconfiguration** when admins can't tell which policy instance is active
- 🕐 **Manual effort** to compare XML files across versions

---

## 💡 The Solution

**ADMxSquizer** ("ADMX Squeezer") solves this by generating **delta ADMX/ADML files** that contain **only the new policies** added between two Chrome versions.

Each output file has a **unique versioned namespace** (`Google.Policies.Chrome.v146`), so Intune treats them as distinct policy definitions — no conflicts, no duplicates.

```
Chrome v141 (690 policies)  ─┐
                              ├──► Delta v143 (4 new policies)
Chrome v143 (694 policies)  ─┤
                              ├──► Delta v146 (25 new policies)
Chrome v146 (719 policies)  ─┘
```

---

## 🚀 Quick Start

### Prerequisites

- **PowerShell 5.1+** (included in Windows 10/11)
- Chrome ADMX templates downloaded from [Google Enterprise](https://chromeenterprise.google/policies/)

### Usage

```powershell
.\Compare-ADMXPolicies.ps1 `
    -BaselineAdmxPath ".\GoogleChromeADMx\policy_templates_141\windows\admx\chrome.admx" `
    -NewerAdmxPath    ".\GoogleChromeADMx\policy_templates_146\windows\admx\chrome.admx" `
    -OutputFolder     ".\IntuneADMX" `
    -BaselineVersion  "141" `
    -NewerVersion     "146"
```

### Output

```
IntuneADMX/
└── chrome_v146_delta_from_v141/
    ├── chrome_v146_delta_from_v141.admx    ← Upload this to Intune
    ├── en-US/
    │   └── chrome_v146_delta_from_v141.adml
    ├── it-IT/
    │   └── chrome_v146_delta_from_v141.adml
    └── ... (18 languages)
```

---

## 📦 Parameters

| Parameter | Description | Example |
|---|---|---|
| `BaselineAdmxPath` | Path to the older chrome.admx | `.\policy_templates_141\...\chrome.admx` |
| `NewerAdmxPath` | Path to the newer chrome.admx | `.\policy_templates_146\...\chrome.admx` |
| `OutputFolder` | Where to write the delta files | `.\IntuneADMX` |
| `BaselineVersion` | Short label for the baseline | `141` |
| `NewerVersion` | Short label for the newer version | `146` |

---

## 🔍 How It Works

1. **Parse** both ADMX files as XML
2. **Compare** policy `name` attributes to identify additions
3. **Resolve** all dependencies — categories, string IDs, presentation elements
4. **Generate** a new ADMX with a **versioned namespace** (`Google.Policies.Chrome.v{version}`)
5. **Generate** matching ADML files for each language (intersection of both versions)
6. **Validate** output is well-formed XML

### What makes the output Intune-compatible

| Feature | Details |
|---|---|
| 🏷️ **Versioned namespace** | `Google.Policies.Chrome.v146` prevents conflicts with other imports |
| 📄 **Versioned filename** | `chrome_v146_delta_from_v141.admx` makes the scope clear |
| 🌐 **Multi-language ADML** | All 18 languages supported by Chrome Enterprise |
| ✂️ **Minimal footprint** | Only new policies + their dependencies |

---

## 📊 Example Results

With Chrome versions 141, 143, and 146:

| Comparison | New Policies | Example Policies |
|---|---|---|
| **141 → 143** | 4 | `GeminiActOnWebSettings`, `LocalNetworkAccessRestrictionsTemporaryOptOut` |
| **143 → 146** | 25 | `GeolocationBlockedForUrls`, `XSLTEnabled`, `CacheEncryptionEnabled` |
| **141 → 146** | 29 | All of the above combined |

✅ Consistency verified: 4 + 25 = 29

---

## 📁 Repository Structure

```
ADMxSquizer/
├── Compare-ADMXPolicies.ps1          # Main PowerShell script
├── GoogleChromeADMx/                 # Source Chrome ADMX templates
│   ├── policy_templates_141/
│   ├── policy_templates_143/
│   └── policy_templates_146/
├── IntuneADMX/                       # Generated delta output
│   ├── chrome_v143_delta_from_v141/
│   ├── chrome_v146_delta_from_v143/
│   └── chrome_v146_delta_from_v141/
└── .github/
    └── copilot-instructions.md
```

---

## 🔄 Adding a New Chrome Version

1. Download the new ADMX templates from [Google Enterprise](https://chromeenterprise.google/policies/)
2. Extract to `GoogleChromeADMx/policy_templates_{version}/`
3. Run the script against the previous version:

```powershell
.\Compare-ADMXPolicies.ps1 `
    -BaselineAdmxPath ".\GoogleChromeADMx\policy_templates_146\windows\admx\chrome.admx" `
    -NewerAdmxPath    ".\GoogleChromeADMx\policy_templates_149\windows\admx\chrome.admx" `
    -OutputFolder     ".\IntuneADMX" `
    -BaselineVersion  "146" `
    -NewerVersion     "149"
```

4. Upload the generated ADMX/ADML to Intune

---

## 📤 Uploading to Intune

1. Go to **Microsoft Intune admin center** → **Devices** → **Configuration** → **Import ADMX**
2. Upload the `.admx` file from the delta folder
3. Upload the `.adml` file from the `en-US` subfolder (or your preferred language)
4. The new policies will appear in the **Settings Catalog** without duplicating existing ones

---

## 🤝 Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.

## 📄 License

This project is licensed under the [MIT License](LICENSE).
