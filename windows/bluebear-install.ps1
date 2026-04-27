# BlueBear Windows Installer
# DEN-275: PowerShell installer script
# DEN-750: Updated for single binary architecture (unified handler)
# DEN-1017: Simplified installer — OAuth moved to Go binary (`bluebear enable`)
#
# Usage:
#   # Interactive install (Go binary opens browser for authentication)
#   irm https://install.bluebearsecurity.io/windows | iex
#
#   # Or run directly
#   .\install.ps1
#
#   # With custom API URL (for development)
#   $env:BLUEDEN_API_URL = "https://api-pr-123.dev.bluebearsecurity.io"
#   .\install.ps1

#Requires -Version 5.1

param(
    [string]$ApiUrl = $env:BLUEDEN_API_URL,
    [string]$DownloadUrl = $env:BLUEBEAR_DOWNLOAD_URL,
    [string]$ArtifactId = $env:BLUEBEAR_ARTIFACT_ID,
    [string]$InstallDir = $null,
    [switch]$NoAddToPath,
    [switch]$Force,
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # Speeds up Invoke-WebRequest

# Default URLs
if (-not $ApiUrl) { $ApiUrl = "https://api.bluebearsecurity.io" }
# DEN-1017: Download URL defaults to GitHub Release URL for prod.
# Dev/PR uses artifact download via gh CLI (when ArtifactId is set).
if (-not $DownloadUrl) { $DownloadUrl = "https://github.com/Blue-Bear-Security/homebrew-handler/releases/download/handler-v0.6.25" }

# Installation paths
if (-not $InstallDir) {
    $InstallDir = Join-Path $env:LOCALAPPDATA "BlueBear"
}
$BinDir = Join-Path $InstallDir "bin"

# Version - will be replaced by CI/CD (e.g., 0.0.478 for PR, 1.2.3 for prod)
$Version = "0.6.25"

# Detect PR version from API URL if not replaced by CI/CD
if ($Version -eq "__VERSION__") {
    if ($ApiUrl -match "api-pr-(\d+)") {
        # For local dev: use PR number as version for S3 path compatibility
        $Version = "0.0.$($Matches[1])"
    } else {
        # Fallback to latest for production when version not set
        $Version = "latest"
    }
}

# DEN-750: Detect environment from API URL for config dir and exe naming
# This is separate from Version because Version is used for S3 download path
$Environment = ""
if ($ApiUrl -match "api-pr-(\d+)") {
    $Environment = "pr-$($Matches[1])"
}

# DEN-750: Config directory matches Go binary's environmentSuffix
# PR environments use .bluebear-pr-{N}, production uses .bluebear
if ($Environment -match "^pr-\d+$") {
    $ConfigDir = Join-Path $env:USERPROFILE ".bluebear-$Environment"
} else {
    $ConfigDir = Join-Path $env:USERPROFILE ".bluebear"
}
$ConfigFile = Join-Path $ConfigDir "config"

# DEN-750: Single binary architecture
# All clients (Claude, Copilot, Cursor, Codex) are now handled by a single unified binary

# Helper functions
function Write-Status {
    param([string]$Message, [string]$Type = "Info")
    switch ($Type) {
        "Success" { Write-Host "==> " -ForegroundColor Green -NoNewline; Write-Host $Message }
        "Warning" { Write-Host "==> " -ForegroundColor Yellow -NoNewline; Write-Host $Message }
        "Error" { Write-Host "==> " -ForegroundColor Red -NoNewline; Write-Host $Message }
        default { Write-Host "==> " -ForegroundColor Cyan -NoNewline; Write-Host $Message }
    }
}

function Write-Detail {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Gray
}

function Test-ValidUrl {
    # Validate URL is a proper HTTPS URL to prevent SSRF attacks
    param([string]$Url, [string]$Name)

    if (-not $Url) {
        Write-Status "$Name URL is required" -Type "Error"
        return $false
    }

    # Must be HTTPS
    if (-not $Url.StartsWith("https://")) {
        Write-Status "$Name URL must use HTTPS: $Url" -Type "Error"
        return $false
    }

    # Parse URL to validate format
    try {
        $uri = [System.Uri]::new($Url)

        # Must have valid host
        if ([string]::IsNullOrEmpty($uri.Host)) {
            Write-Status "$Name URL has invalid host: $Url" -Type "Error"
            return $false
        }

        # Block localhost/internal IPs for production
        $urlHost = $uri.Host.ToLower()
        if ($urlHost -eq "localhost" -or $urlHost -eq "127.0.0.1" -or $urlHost.StartsWith("192.168.") -or $urlHost.StartsWith("10.") -or $urlHost.StartsWith("172.")) {
            # Allow for development but warn
            Write-Status "$Name URL points to local/internal address: $Url" -Type "Warning"
        }

        return $true
    } catch {
        Write-Status "$Name URL is malformed: $Url" -Type "Error"
        return $false
    }
}

function Set-ConfigFilePermissions {
    # Config file is in user's profile folder (~\.bluebear) which is already protected
    # by Windows user profile permissions. No additional ACL changes needed.
    # The developer_api_key is stored in this config file for simplicity.
    # Windows user profile permissions provide adequate protection.
    param([string]$FilePath)

    # Just mark the file as hidden for extra obscurity (optional, non-critical)
    try {
        $file = Get-Item $FilePath -Force
        $file.Attributes = $file.Attributes -bor [System.IO.FileAttributes]::Hidden
    } catch {
        # Ignore errors - this is just cosmetic
    }

    return $true
}

function Write-ConfigFile {
    # Safely write to config file, handling edge cases like:
    # - Config path exists as a directory (cleanup from failed installs)
    # - Config file exists with restrictive permissions
    # - Config file is locked by another process
    param(
        [string]$FilePath,
        [string]$Content
    )

    $parentDir = Split-Path -Parent $FilePath

    # Ensure parent directory exists
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    # Remove existing file/directory at config path
    if (Test-Path $FilePath) {
        try {
            # Reset attributes first (in case it's hidden/readonly)
            $item = Get-Item $FilePath -Force
            $item.Attributes = [System.IO.FileAttributes]::Normal
        } catch {
            # Ignore attribute reset errors
        }
        Remove-Item -Path $FilePath -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Write UTF-8 without BOM (PowerShell 5.1 compatible)
    [System.IO.File]::WriteAllText($FilePath, $Content, [System.Text.UTF8Encoding]::new($false))
}

# Note: Config management functions (Test-ExistingConfig, New-ApiKey) removed in DEN-1017.
# The Go binary handles all config detection and credential setup via `bluebear enable`.

# Note: OAuth device flow functions (Start-DeviceAuth, Wait-ForAuth, New-ApiKey) removed in DEN-1017.
# All authentication is now handled by the Go binary (`bluebear enable`).

function Get-BlueBearBinary {
    # DEN-750: Downloads the single unified BlueBear binary
    # DEN-1017: Prod uses GitHub Release assets (public). Dev/PR uses gh CLI for artifact download.

    $platform = "windows-x86_64"
    $binaryName = "bluebear-$platform.exe"
    $zipName = "$binaryName.zip"
    $checksumName = "$zipName.sha256"
    $zipPath = Join-Path $env:TEMP $zipName
    $checksumPath = Join-Path $env:TEMP $checksumName
    $extractPath = Join-Path $env:TEMP "bluebear-extract"

    Write-Status "Downloading BlueBear..."

    try {
        if ($ArtifactId) {
            # Dev/PR: download artifact via gh CLI (requires auth)
            Write-Detail "Using GitHub Actions artifact: $ArtifactId"
            $artifactZipPath = Join-Path $env:TEMP "artifact-$ArtifactId.zip"
            gh api "repos/Blue-Bear-Security/blueden/actions/artifacts/$ArtifactId/zip" --output $artifactZipPath
            if (-not (Test-Path $artifactZipPath) -or (Get-Item $artifactZipPath).Length -lt 1000) {
                throw "Failed to download artifact $ArtifactId via gh CLI"
            }
            # Artifact is zip-wrapped: outer zip contains the .exe.zip
            $artifactExtractPath = Join-Path $env:TEMP "artifact-extract"
            if (Test-Path $artifactExtractPath) { Remove-Item -Path $artifactExtractPath -Recurse -Force }
            Expand-Archive -Path $artifactZipPath -DestinationPath $artifactExtractPath -Force
            # Find the .exe.zip inside the artifact
            $innerZip = Get-ChildItem -Path $artifactExtractPath -Filter "*.zip" -Recurse | Select-Object -First 1
            if ($innerZip) {
                Copy-Item -Path $innerZip.FullName -Destination $zipPath -Force
            } else {
                # Artifact may contain the exe directly
                Copy-Item -Path "$artifactExtractPath\*" -Destination $env:TEMP -Force
                if (-not (Test-Path $zipPath)) { throw "Could not find binary zip inside artifact" }
            }
            Remove-Item -Path $artifactZipPath -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $artifactExtractPath -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            # Prod: direct download from GitHub Release URL
            $binaryDownloadUrl = "$DownloadUrl/$zipName"
            $checksumDownloadUrl = "$DownloadUrl/$checksumName"

            Invoke-WebRequest -Uri $binaryDownloadUrl `
                -OutFile $zipPath `
                -ErrorAction Stop
        }

        if ((Get-Item $zipPath).Length -lt 1000) {
            throw "Downloaded file too small"
        }

        # Download and verify SHA256 checksum (prod only, not for artifact downloads)
        if (-not $ArtifactId) {
            try {
                Invoke-WebRequest -Uri $checksumDownloadUrl `
                    -OutFile $checksumPath `
                    -ErrorAction Stop

                # Read expected checksum (format: "hash  filename" or just "hash")
                $expectedChecksum = (Get-Content $checksumPath -Raw).Trim().Split()[0].ToLower()

                # Calculate actual checksum
                $actualChecksum = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLower()

                if ($expectedChecksum -ne $actualChecksum) {
                    Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
                    Remove-Item -Path $checksumPath -Force -ErrorAction SilentlyContinue
                    throw "SHA256 checksum verification failed! Expected: $expectedChecksum, Got: $actualChecksum. The download may have been tampered with."
                }

                Write-Detail "SHA256 checksum verified"
                Remove-Item -Path $checksumPath -Force -ErrorAction SilentlyContinue
            } catch [System.Net.WebException] {
                # Checksum file unavailable — fail loudly to prevent installing an unverified binary.
                # An attacker who blocks the .sha256 file while serving a malicious binary would
                # otherwise bypass verification silently.
                throw "SHA256 checksum file could not be downloaded from $checksumDownloadUrl. Installation aborted. If this is expected, verify your network connectivity and try again."
            }
        }

        # Extract zip
        if (Test-Path $extractPath) {
            Remove-Item -Path $extractPath -Recurse -Force
        }

        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

        # Find extracted content (handles both direct and nested extraction)
        $extractedDir = Get-ChildItem -Path $extractPath -Directory | Select-Object -First 1
        if ($extractedDir) {
            $sourcePath = $extractedDir.FullName
        } else {
            $sourcePath = $extractPath
        }

        # Copy files to install directory
        Copy-Item -Path "$sourcePath\*" -Destination $InstallDir -Recurse -Force

        # Rename platform-specific binary to environment-specific name
        # Production: bluebear.exe, PR: bluebear-pr-{N}.exe
        $platformBinary = Join-Path $InstallDir "bluebear-$platform.exe"
        $exeName = if ($Environment) { "bluebear-$Environment.exe" } else { "bluebear.exe" }
        $standardBinary = Join-Path $InstallDir $exeName
        if (Test-Path $platformBinary) {
            Move-Item -Path $platformBinary -Destination $standardBinary -Force
        }

        # Cleanup
        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $extractPath -Recurse -Force -ErrorAction SilentlyContinue

        Write-Status "Downloaded BlueBear binary" -Type "Success"
        return $true
    } catch {
        Write-Status "Failed to download BlueBear: $_" -Type "Error"
        return $false
    }
}

function Copy-UninstallScript {
    # Bundle uninstall script with the installation (version-matched)
    # This ensures users always have an uninstaller that matches their installed version
    Write-Status "Bundling uninstall script..."

    # Determine executable name based on environment
    $exeName = if ($Environment) { "bluebear-$Environment.exe" } else { "bluebear.exe" }

    $uninstallPath = Join-Path $InstallDir "uninstall.ps1"
    $uninstallContent = @"
# BlueBear Windows Uninstaller (bundled with installation)
# Run: bluebear-uninstall
#      or: powershell -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\BlueBear\uninstall.ps1"

param([switch]`$KeepConfig, [switch]`$Force)

`$ErrorActionPreference = "Stop"
`$InstallDir = Join-Path `$env:LOCALAPPDATA "BlueBear"
`$BinDir = Join-Path `$InstallDir "bin"
`$ConfigDir = "$ConfigDir"

# Change to user's home directory to avoid "path not found" errors
# when uninstall deletes the current working directory
Set-Location `$env:USERPROFILE

Write-Host ""
Write-Host "BlueBear Windows Uninstaller" -ForegroundColor Cyan
Write-Host "============================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path `$InstallDir)) {
    Write-Host "==> BlueBear is not installed" -ForegroundColor Yellow
    exit 0
}

if (-not `$Force) {
    `$confirm = Read-Host "Are you sure you want to uninstall BlueBear? (y/N)"
    if (`$confirm -ne "y" -and `$confirm -ne "Y") {
        Write-Host "==> Uninstall cancelled"
        exit 0
    }
}

# Run bluebear disable to clean up hooks and daemon
`$bluebearExe = Join-Path `$InstallDir "$exeName"
if (Test-Path `$bluebearExe) {
    Write-Host "==> Running BlueBear cleanup..." -ForegroundColor Cyan
    try { & `$bluebearExe disable 2>&1 | ForEach-Object { Write-Host "    `$_" -ForegroundColor Gray } } catch {}
}

# Stop any remaining processes
Write-Host "==> Stopping BlueBear processes..." -ForegroundColor Cyan
Get-Process -Name "bluebear*" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# Remove from PATH
Write-Host "==> Removing from PATH..." -ForegroundColor Cyan
`$path = [Environment]::GetEnvironmentVariable("PATH", "User")
`$newPath = (`$path -split ";" | Where-Object { `$_ -ne `$BinDir -and `$_ }) -join ";"
[Environment]::SetEnvironmentVariable("PATH", `$newPath, "User")

# Remove PowerShell completion
Write-Host "==> Removing PowerShell completion..." -ForegroundColor Cyan
try {
    `$profileDir = Split-Path -Parent `$PROFILE
    # Remove completion files
    Get-ChildItem -Path `$profileDir -Filter "bluebear*.completion.ps1" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    # Clean profile
    if (Test-Path `$PROFILE) {
        `$content = Get-Content `$PROFILE -Raw -ErrorAction SilentlyContinue
        if (`$content) {
            `$newContent = `$content -replace '(?m)^\s*# BlueBear CLI completion\s*\r?\n\s*if \(Test-Path "[^"]*bluebear[^"]*\.completion\.ps1"\) \{ \. "[^"]*" \}\s*\r?\n?', ''
            if (`$newContent -ne `$content) { [System.IO.File]::WriteAllText(`$PROFILE, `$newContent) }
        }
    }
} catch {}

# Remove startup scripts
Write-Host "==> Removing startup scripts..." -ForegroundColor Cyan
`$startupFolder = Join-Path `$env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
Remove-Item "`$startupFolder\BlueBear*.vbs" -Force -ErrorAction SilentlyContinue

# Remove installation directory
Write-Host "==> Removing installation directory..." -ForegroundColor Cyan
Remove-Item -Path `$InstallDir -Recurse -Force -ErrorAction SilentlyContinue

# Remove config directory
if (-not `$KeepConfig) {
    Write-Host "==> Removing configuration..." -ForegroundColor Cyan
    Remove-Item -Path `$ConfigDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "==> BlueBear has been uninstalled" -ForegroundColor Green
Write-Host ""
"@

    Set-Content -Path $uninstallPath -Value $uninstallContent -Encoding UTF8
    Write-Status "Bundled uninstall script" -Type "Success"
}

function New-WrapperScripts {
    # DEN-750: Creates wrapper scripts for the unified binary
    # PR environments use env-suffixed names (bluebear-pr-478, bluebear-pr-478-uninstall)
    Write-Status "Creating wrapper scripts..."

    if (-not (Test-Path $BinDir)) {
        New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    }

    # Determine names based on environment
    $exeBaseName = if ($Environment) { "bluebear-$Environment" } else { "bluebear" }

    # Create main wrapper that calls the binary directly
    $mainWrapperPath = Join-Path $BinDir "$exeBaseName.bat"
    $mainWrapperContent = @"
@echo off
"%LOCALAPPDATA%\BlueBear\$exeBaseName.exe" %*
"@
    Set-Content -Path $mainWrapperPath -Value $mainWrapperContent -Encoding ASCII

    # Create uninstall wrapper that runs the bundled uninstall script
    # Note: The 2>nul suppresses "system cannot find the path specified" errors that occur
    # when the batch file is deleted during uninstall (the uninstall still succeeds)
    $uninstallWrapperPath = Join-Path $BinDir "$exeBaseName-uninstall.bat"
    $uninstallWrapperContent = @"
@echo off
powershell -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\BlueBear\uninstall.ps1" %* 2>nul
exit /b 0
"@
    Set-Content -Path $uninstallWrapperPath -Value $uninstallWrapperContent -Encoding ASCII

    Write-Status "Created wrapper scripts" -Type "Success"
}

function Add-ToPath {
    Write-Status "Adding BlueBear to PATH..."

    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")

    if ($currentPath -split ";" -contains $BinDir) {
        Write-Detail "Already in PATH"
        return
    }

    $newPath = "$currentPath;$BinDir"
    [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")

    # Also update current session
    $env:PATH = "$env:PATH;$BinDir"

    Write-Status "Added to PATH" -Type "Success"
    Write-Detail "You may need to restart your terminal for PATH changes to take effect"
}

function Save-InstallInfo {
    # DEN-750: Simplified for single binary - no longer tracks individual clients

    # Load existing config or create new
    $config = @{}
    if (Test-Path $ConfigFile) {
        try {
            # PowerShell 5.1 compatible: convert PSCustomObject to hashtable
            $json = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            $config = @{}
            $json.PSObject.Properties | ForEach-Object { $config[$_.Name] = $_.Value }
        } catch {
            $config = @{}
        }
    }

    $config["version"] = $Version
    $config["platform"] = "windows-x86_64"
    $config["install_type"] = "powershell"
    $config["install_dir"] = $InstallDir

    # Write config file safely (handles permission issues)
    $jsonContent = $config | ConvertTo-Json
    Write-ConfigFile -FilePath $ConfigFile -Content $jsonContent

    # Set restrictive file permissions (current user only)
    Set-ConfigFilePermissions -FilePath $ConfigFile | Out-Null
}

function Install-PowerShellCompletion {
    # Install PowerShell completion script to user's profile directory
    # This enables tab completion for bluebear commands in PowerShell
    param([string]$ExePath, [string]$ExeBaseName)

    Write-Status "Installing PowerShell completion..."

    try {
        # Generate completion script
        $completionScript = & $ExePath completion powershell 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Detail "Could not generate completion script"
            return
        }

        # Get PowerShell profile directory (not the profile script itself)
        $profileDir = Split-Path -Parent $PROFILE

        # Create profile directory if it doesn't exist
        if (-not (Test-Path $profileDir)) {
            New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        }

        # Save completion script to a separate file
        $completionFile = Join-Path $profileDir "$ExeBaseName.completion.ps1"
        $completionScript | Set-Content -Path $completionFile -Encoding UTF8

        # Check if profile exists and if it already sources the completion
        $profileContent = ""
        if (Test-Path $PROFILE) {
            $profileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
        }

        $sourceCommand = ". `"$completionFile`""

        if ($profileContent -notmatch [regex]::Escape($completionFile)) {
            # Add sourcing command to profile
            $profileAddition = @"

# BlueBear CLI completion
if (Test-Path "$completionFile") { $sourceCommand }
"@

            Add-Content -Path $PROFILE -Value $profileAddition -Encoding UTF8
            Write-Status "PowerShell completion installed" -Type "Success"
            Write-Detail "Completion will be available in new PowerShell sessions"
            Write-Detail "Or run: . `"$completionFile`""
        } else {
            Write-Detail "PowerShell completion already configured"
        }
    } catch {
        Write-Detail "Could not install PowerShell completion: $_"
    }
}

# Main installation flow
function Install-BlueBear {
    Write-Host ""
    Write-Host "BlueBear Windows Installer" -ForegroundColor Cyan
    Write-Host "=========================" -ForegroundColor Cyan
    Write-Host ""

    # Validate URLs before proceeding
    if (-not (Test-ValidUrl -Url $DownloadUrl -Name "Download")) {
        Write-Host ""
        Write-Host "Installation aborted due to invalid Download URL." -ForegroundColor Red
        exit 1
    }

    # Create installation directory
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    # DEN-1017: Download binary (no auth needed for prod via CloudFront)
    if (-not (Get-BlueBearBinary)) {
        Write-Status "Failed to download BlueBear binary" -Type "Error"
        exit 1
    }

    # Bundle uninstall script (version-matched)
    Copy-UninstallScript

    # Create wrapper scripts
    New-WrapperScripts

    # Add to PATH unless disabled
    if (-not $NoAddToPath) {
        Add-ToPath
    }

    # Save installation info
    Save-InstallInfo

    # Determine executable name based on environment
    $exeName = if ($Environment) { "bluebear-$Environment.exe" } else { "bluebear.exe" }
    $exeBaseName = if ($Environment) { "bluebear-$Environment" } else { "bluebear" }
    $bluebearExe = Join-Path $InstallDir $exeName

    # Install PowerShell completion
    Install-PowerShellCompletion -ExePath $bluebearExe -ExeBaseName $exeBaseName

    # DEN-1017: The Go binary handles all auth — installer just calls `enable`.
    # DEN-842: Do not pipe output so stdin is inherited for interactive prompts.
    Write-Status "Running $exeBaseName enable..."
    try {
        & $bluebearExe enable
        Write-Status "BlueBear daemon enabled and started" -Type "Success"
    } catch {
        Write-Status "Failed to set up daemon: $_" -Type "Warning"
        Write-Detail "You can manually start the daemon with: $exeBaseName enable"
    }

    Write-Host ""
    Write-Status "BlueBear installation complete!" -Type "Success"
    Write-Host ""
    Write-Host "    To uninstall: " -NoNewline
    Write-Host "$exeBaseName-uninstall" -ForegroundColor Yellow
    Write-Host ""
}

# Run installation
Install-BlueBear
