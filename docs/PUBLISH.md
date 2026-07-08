# HVDRS — Publishing to PowerShell Gallery

This document covers how to publish the HVDRS module to [PowerShell Gallery](https://www.powershellgallery.com). The publishing scripts and configuration in the `Publish/` directory are not included in the distributed module package.

---

## Prerequisites

### PowerShell Gallery account

1. Sign in at [powershellgallery.com](https://www.powershellgallery.com) with a Microsoft account.
2. Navigate to your profile → **API Keys**.
3. Click **Create** and configure a key:
   - **Key name**: something descriptive, e.g. `HVDRS-publish`
   - **Expiration**: set an appropriate window (365 days is typical)
   - **Scope**: push new packages and package versions
   - **Glob pattern**: `HVDRS` (restricts the key to this module only)
4. Copy the generated key immediately — it is only shown once.

### NuGet provider

The `Publish-Module` cmdlet requires the NuGet package provider. Install it if it is not already present:

```powershell
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
```

### Pester 5 (optional, for pre-publish test run)

```powershell
Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck
```

If Pester 5 is not installed the publish script will warn and skip the test run rather than failing.

---

## First-Time Setup

1. Copy the config template to create your local config file:

   ```powershell
   Copy-Item Publish\publish.config.template.json Publish\publish.config.json
   ```

2. Open `Publish\publish.config.json` and replace the placeholder with your API key:

   ```json
   {
       "ApiKey":     "ps_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
       "Repository": "PSGallery"
   }
   ```

3. `Publish\publish.config.json` is listed in `.gitignore` and will never be committed to the repository. Do not remove it from `.gitignore`.

---

## Pre-Publish Checklist

Before publishing a new version, complete the following steps:

- [ ] **Bump the version** in `HVDRS.psd1` → `ModuleVersion`. Follow [SemVer](https://semver.org/): patch for bug fixes, minor for new features, major for breaking changes.
- [ ] **Update ReleaseNotes** in `HVDRS.psd1` → `PrivateData.PSData.ReleaseNotes` to describe what changed in this version.
- [ ] **Run the test suite** and confirm all tests pass:
  ```powershell
  Invoke-Pester ./Tests/ -Output Detailed
  ```
- [ ] **Validate the manifest** to catch syntax errors early:
  ```powershell
  Test-ModuleManifest -Path .\HVDRS.psd1
  ```
- [ ] **Commit and push** all changes to the repository before publishing so that the gallery version matches what is in source control.
- [ ] **Dry run** the publish script (see below) to confirm staging looks correct.

---

## Publishing

### Dry run (recommended first)

Preview what would be staged and uploaded without actually publishing:

```powershell
.\Publish\Publish-HvDRS.ps1 -WhatIf
```

The `-WhatIf` output lists every file that would be included in the package and preserves the staging directory so you can inspect its contents.

### Live publish

```powershell
.\Publish\Publish-HvDRS.ps1
```

The script will:

1. Load `Publish\publish.config.json` and validate the API key is set.
2. Run `Test-ModuleManifest` against `HVDRS.psd1`.
3. Run the Pester test suite (unless `-SkipTests` is passed).
4. Copy the module files to a temporary staging directory, excluding:
   - `Publish\` — this directory (scripts and config)
   - `Tests\`, `ProPack\` — the test suites (compute and ProPack)
   - `docs\PUBLISH.md` — this document (removed from the staged copy after `docs\` is copied)
   - `.gitignore`, `.gitattributes`
5. Call `Publish-Module` against the staging directory.
6. Clean up the staging directory.

On success the published package URL is printed.

### Skip the test run

```powershell
.\Publish\Publish-HvDRS.ps1 -SkipTests
```

Use this only when you have already run the test suite separately and are confident the code is clean.

### Use a custom config path

If you keep your API key in a different location:

```powershell
.\Publish\Publish-HvDRS.ps1 -ConfigPath D:\secrets\hvdrs-publish.json
```

---

## What Gets Published

The staging step includes everything in the repository **except**:

| Excluded path | Reason |
|---|---|
| `Publish\` | Publish scripts and credentials — not part of the module |
| `Tests\`, `ProPack\` | Pester test suites — not needed by end users (`ProPack\` is also an optional, separately-installed add-on) |
| `docs\PUBLISH.md` | Developer documentation — not relevant to module consumers |
| `.gitignore` | Source control artifact |

Everything else ships with the package: `HVDRS.psd1`, `HVDRS.psm1`, `Functions\`, `README.md`, `LICENSE`, and the rest of `docs\` (`INSTALL.md`, `USAGE.md`, `TESTS.md`, `ARCHITECTURE.md`).

---

## Version Management

HVDRS uses [Semantic Versioning](https://semver.org/):

| Change type | Version component | Example |
|---|---|---|
| Bug fix, minor correction | Patch (`x.x.Z`) | 1.2.0 → 1.2.1 |
| New function or parameter | Minor (`x.Y.0`) | 1.2.1 → 1.3.0 |
| Removed function, changed behavior | Major (`X.0.0`) | 1.3.0 → 2.0.0 |

PowerShell Gallery does not allow republishing the same version number. If you need to fix a publish mistake, increment the patch version.

---

## Verifying the Published Package

After a successful publish, the new version typically appears on the gallery within a few minutes:

```powershell
# Find the module on the gallery
Find-Module -Name HVDRS

# Install the newly published version to verify it installs cleanly
Install-Module HVDRS -Force
Get-Command -Module HVDRS
```

---

## API Key Rotation

API keys expire based on the expiration window you set when creating them. To rotate:

1. Generate a new key at [powershellgallery.com](https://www.powershellgallery.com) → **API Keys**.
2. Update `Publish\publish.config.json` with the new key.
3. Delete the old key from the gallery once the new one is confirmed working.

Never commit `publish.config.json` to version control, even after the key expires.
