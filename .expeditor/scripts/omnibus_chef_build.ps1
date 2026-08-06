#Requires -Version 5.1
# Chef omnibus build with Progress EV code signing via Azure Key Vault
# Mirrors chef-installer-scripts windows-sign.ps1 flow for Chef-18 builds

$ErrorActionPreference = "Stop"

# Source build-settings from omnibus-buildkite-plugin if available (contains AZURE_* vars)
$buildSettingsPath = "./.omnibus-buildkite-plugin/build-settings.ps1"
if (Test-Path $buildSettingsPath) {
    Write-Output "Sourcing build-settings from omnibus-buildkite-plugin"
    . $buildSettingsPath
}

$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent

# Tool paths
$LocalBin = "$env:USERPROFILE\.local\bin"
New-Item -Path $LocalBin -ItemType Directory -Force | Out-Null
$env:PATH = "$LocalBin;$env:PATH"
$AkeylessExe = "$LocalBin\akeyless.exe"
$DotnetDir = "$env:USERPROFILE\.dotnet"
$env:DOTNET_ROOT = $DotnetDir
$env:PATH = "$DotnetDir\tools;$DotnetDir;$env:PATH"

function Initialize-Environment {
    [CmdletBinding()]
    param()
    
    try {
        Write-Output "Setting up environment variables"
        
        $env:ARTIFACTORY_BASE_PATH = "com/getchef"
        $env:ARTIFACTORY_ENDPOINT = "https://artifactory-internal.ps.chef.co/artifactory"
        $env:ARTIFACTORY_USERNAME = "buildkite"
        
        $env:PROJECT_NAME = "chef"
        $env:OMNIBUS_PIPELINE_DEFINITION_PATH = "${ScriptDir}/../release.omnibus.yml"
        $env:HOMEDRIVE = "C:"
        $env:HOMEPATH = "\Users\ContainerAdministrator"
        $env:OMNIBUS_TOOLCHAIN_INSTALL_DIR = "C:\opscode\omnibus-toolchain"
        $env:SSL_CERT_FILE = "${env:OMNIBUS_TOOLCHAIN_INSTALL_DIR}\embedded\ssl\certs\cacert.pem"
        $env:MSYS2_INSTALL_DIR = "C:\msys64"
        $env:BASH_ENV = "${env:MSYS2_INSTALL_DIR}\etc\bash.bashrc"
        $env:OMNIBUS_WINDOWS_ARCH = "x64"
        
        # Configure MSYSTEM
        $env:MSYSTEM = "MINGW64"
        $omnibus_toolchain_msystem = & "${env:OMNIBUS_TOOLCHAIN_INSTALL_DIR}\embedded\bin\ruby" -e "puts RUBY_PLATFORM"
        if ($omnibus_toolchain_msystem -eq "x64-mingw-ucrt") {
            $env:MSYSTEM = "UCRT64"
        }
        
        # Set PATH
        $original_path = $env:PATH
        $env:PATH = "${env:MSYS2_INSTALL_DIR}\$env:MSYSTEM\bin;${env:MSYS2_INSTALL_DIR}\usr\bin;${env:OMNIBUS_TOOLCHAIN_INSTALL_DIR}\embedded\bin;C:\wix;${original_path}"
        
        Write-Verbose "Environment initialized successfully"
    }
    catch {
        Write-Error "Failed to initialize environment: $_"
        exit 1
    }
}

function Initialize-ProgressSigning {
    [CmdletBinding()]
    param()

    Write-Output "--- Initializing Progress EV code signing"
    
    # Check if Azure credentials already initialized (pre-fetched on host via .buildkite/hooks/pre-command)
    # These are passed to Docker as environment variables
    if ([string]::IsNullOrWhiteSpace($env:AZURE_TENANT_ID) -or `
        [string]::IsNullOrWhiteSpace($env:AZURE_CLIENT_ID) -or `
        [string]::IsNullOrWhiteSpace($env:AZURE_CLIENT_SECRET)) {
        Write-Error @"
Azure credentials (AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET) not found.

These must be pre-fetched on the Windows host via .buildkite/hooks/pre-command:
  1. Fetch AKEYLESS_ACCESS_ID from AWS Parameter Store
  2. Authenticate to Akeyless with AWS IAM
  3. Get dynamic secret from /DevOps/EvCodeSign/evcodesignservice
  4. Export AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET

These env vars are then passed to Docker container for use by omnibus-private's
windows_base.rb during MSI packaging and signing.

Current state:
  AZURE_TENANT_ID = $(if ([string]::IsNullOrWhiteSpace($env:AZURE_TENANT_ID)) { "NOT SET" } else { "SET" })
  AZURE_CLIENT_ID = $(if ([string]::IsNullOrWhiteSpace($env:AZURE_CLIENT_ID)) { "NOT SET" } else { "SET" })
  AZURE_CLIENT_SECRET = $(if ([string]::IsNullOrWhiteSpace($env:AZURE_CLIENT_SECRET)) { "NOT SET" } else { "SET" })
"@
        exit 1
    }
    
    Write-Output "[OK] Azure credentials present"
    
    # Set OMNIBUS_AZURE_* environment variables for omnibus-private's windows_base.rb to use during signing
    if ([string]::IsNullOrWhiteSpace($env:OMNIBUS_AZURE_KEY_VAULT_URL)) {
        $env:OMNIBUS_AZURE_KEY_VAULT_URL = "https://caps-evcodesign-useast.vault.azure.net"
    }
    if ([string]::IsNullOrWhiteSpace($env:OMNIBUS_AZURE_CERT_NAME)) {
        $env:OMNIBUS_AZURE_CERT_NAME = "psc-evcodesign"
    }
    
    Write-Output "Progress EV signing will be handled by omnibus-private during MSI packaging"
    Write-Output "  OMNIBUS_AZURE_KEY_VAULT_URL = $env:OMNIBUS_AZURE_KEY_VAULT_URL"
    Write-Output "  OMNIBUS_AZURE_CERT_NAME = $env:OMNIBUS_AZURE_CERT_NAME"
}
}

function Sign-ChefPackage {
    [CmdletBinding()]
    param()
    
    Write-Output "--- Verifying Chef MSI signature (signed by omnibus-private during build)"
    
    try {
        # Find MSI file in omnibus package directory
        $msiPath = Get-ChildItem -Path "C:\omnibus-ruby\chef\pkg\" -Filter "*.msi" -ErrorAction SilentlyContinue | Select-Object -First 1
        
        if (-not $msiPath) {
            Write-Warning "No MSI file found in C:\omnibus-ruby\chef\pkg\ - packaging may have been skipped"
            return
        }
        
        $msiPath = $msiPath.FullName
        Write-Output "Found MSI: $(Split-Path $msiPath -Leaf)"
        
        # Verify signature (omnibus-private should have signed this during packaging)
        Write-Output "Verifying signature..."
        $sig = Get-AuthenticodeSignature -FilePath $msiPath
        
        Write-Output "  Status: $($sig.Status)"
        Write-Output "  Subject: $($sig.SignerCertificate.Subject)"
        Write-Output "  Issuer: $($sig.SignerCertificate.Issuer)"
        Write-Output "  Valid From: $($sig.SignerCertificate.NotBefore)"
        Write-Output "  Valid To: $($sig.SignerCertificate.NotAfter)"
        Write-Output "  Thumbprint: $($sig.SignerCertificate.Thumbprint)"
        
        if ($sig.Status -ne 'Valid') {
            Write-Error "Signature verification failed: $($sig.Status)"
            if ($sig.StatusMessage) {
                Write-Error "  Details: $($sig.StatusMessage)"
            }
            exit 1
        }
        
        Write-Output "[OK] MSI signature is valid"
        
        # Check if it's Progress EV certificate (should contain "Progress" in issuer)
        if ($sig.SignerCertificate.Issuer -like "*Progress*") {
            Write-Output "[OK] Signed with Progress EV certificate"
        } else {
            Write-Warning "Certificate issuer does not contain 'Progress'. Issuer: $($sig.SignerCertificate.Issuer)"
        }
    }
    catch {
        Write-Error "Failed to verify MSI signature: $_"
        exit 1
    }
}

function Install-ChefFoundation {
    [CmdletBinding()]
    param(
      # this is to pass into the msiURL, for now its static, but if we want to change it in the future for a different version we can.
        [string]$Version = $env:CHEF_FOUNDATION_VERSION,
        [string]$WindowsVersion = "2022",
        [string]$Architecture = "x64"
    )
    
    try {
        Write-Output "--- Installing Chef Foundation ${Version}"
        
        # Create temp directory if it doesn't exist
        $tempDir = Join-Path $env:TEMP "chef-foundation"
        if (-not (Test-Path $tempDir)) {
            New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
        }
        
        # Build MSI file URL and stops using old api and goes direct to packages.
        $msiUrl = "https://packages.chef.io/files/stable/chef-foundation/${Version}/windows/${WindowsVersion}/chef-foundation-${Version}-1-${Architecture}.msi"
        $msiFile = Join-Path $tempDir "chef-foundation-$Version.msi"
        
        Write-Output "Downloading from $msiUrl to $msiFile"
        
        # Download the MSI
        Invoke-WebRequest -Uri $msiUrl -OutFile $msiFile -UseBasicParsing
        if (-not $?) { 
            throw "Failed to download Chef Foundation MSI from $msiUrl" 
        }
        
        # Verify file was downloaded and has content
        if (-not (Test-Path $msiFile) -or (Get-Item $msiFile).Length -eq 0) {
            throw "Downloaded MSI file is missing or empty: $msiFile"
        }
        
        Write-Output "Installing MSI: $msiFile"
        
        # Install the MSI quietly
        $p = Start-Process -FilePath "msiexec.exe" -ArgumentList "/qn /i `"$msiFile`"" -Passthru -Wait -NoNewWindow
        
        # Check installation result
        if ($p.ExitCode -eq 1618) {
            Write-Warning "Another MSI installation is in progress (exit code 1618), installation might be incomplete"
        } 
        elseif ($p.ExitCode -ne 0) {
            throw "MSI installation failed with exit code $($p.ExitCode)"
        }
        
        Write-Output "Chef Foundation $Version installed successfully"
        
        # Optional: Clean up the downloaded MSI
        Remove-Item -Path $msiFile -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Error "Failed to install Chef Foundation: $_"
        exit 1
    }
}

function Install-OmnibusDependencies {
    [CmdletBinding()]
    param()

    try {
        # Remove libyajl2 for reinstall
        Write-Output "--- Removing libyajl2 for reinstall to get libyajldll.a"
        gem uninstall -I libyajl2

        # Validate GITHUB_TOKEN
        if ([string]::IsNullOrEmpty($env:GITHUB_TOKEN)) {
            Write-Error "GITHUB_TOKEN is not set. Cannot access private GitHub dependencies."
            exit 1
        }

        $token = $env:GITHUB_TOKEN.Trim()

        # Create .netrc file for additional auth support
        $netrcPath = "$env:USERPROFILE\_netrc"
        $netrcContent = "machine github.com login $token password x-oauth-basic"
        $netrcContent | Out-File -FilePath $netrcPath -Encoding ascii -Force
        icacls $netrcPath /inheritance:r /grant:r "$($env:USERNAME):(R)"

        # Clear GITHUB_TOKEN from the environment immediately after use
        Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue

        # Configure Bundler for better reliability
        Write-Output "--- Configuring Bundler for private repositories"
        bundle config set --local without development

        # Navigate to omnibus directory
        Set-Location "$($ScriptDir)/../../omnibus"
        Write-Output "--- Running bundle install for Omnibus"
        bundle install

        # Check if the command succeeded
        if ($LASTEXITCODE -ne 0) {
            throw "bundle install failed with exit code $LASTEXITCODE"
        }

        Write-Output "--- Omnibus dependencies installed successfully"
    }
    catch {
        Write-Error "Failed to install Omnibus dependencies: $_"

        # Debug information (directory contents only)
        Write-Output "--- Debug: Current directory contents"
        Get-ChildItem -Force | Select-Object Name, Length

        exit 1
    }
    finally {
        # Clean up credentials for security
        $netrcPath = "$env:USERPROFILE\_netrc"
        if (Test-Path $netrcPath) {
            Remove-Item $netrcPath -Force -ErrorAction SilentlyContinue
        }
    }
}
function Build-ChefPackage {
    [CmdletBinding()]
    param()
    
    try {
        Write-Output "--- Building Chef"
        
        # Change directory to ensure we're in the right place
        Set-Location "$($ScriptDir)/../../omnibus"
        
        # Set up AWS Region
        $AWS_REGION = if ($env:AWS_REGION) { $env:AWS_REGION } else { "us-west-2" }
        
        # Set up build options similar to omnibus-buildkite-plugin
        $BUILD_OPTIONS = "-l internal --populate-s3-cache"
        $BUILD_OPTIONS += " --override"
        $BUILD_OPTIONS += " s3_region:$AWS_REGION"
        $BUILD_OPTIONS += " s3_access_key:$($env:AWS_S3_ACCESS_KEY)"
        $BUILD_OPTIONS += " s3_secret_key:$($env:AWS_S3_SECRET_KEY)"
        $BUILD_OPTIONS += " cache_suffix:$($env:PROJECT_NAME)"
        $BUILD_OPTIONS += " append_timestamp:false"
        $BUILD_OPTIONS += " use_git_caching:true"
        $BUILD_OPTIONS += " --log-level debug"
        
        # Set bundle gemfile
        $env:BUNDLE_GEMFILE = (Get-Location).Path + "/Gemfile"
        Write-Output "Using Gemfile: $env:BUNDLE_GEMFILE"
        
        Write-Output "Starting omnibus build with options: $BUILD_OPTIONS"
        
        # Split BUILD_OPTIONS into an array for proper argument passing
        $buildArgs = $BUILD_OPTIONS -split ' ' | Where-Object { $_ -ne '' }
        
        # Execute the build command
        & bundle exec omnibus build $env:PROJECT_NAME @buildArgs
        
        if ($LASTEXITCODE -ne 0) {
            throw "Omnibus build failed with exit code $LASTEXITCODE"
        }
        
        Write-Output "Omnibus build completed successfully"
    }
    catch {
        Write-Error "Chef build failed: $_"
        
        # Try to get more detailed logs
        Write-Output "--- Attempting to collect detailed build logs"
        Get-ChildItem "C:\omnibus-ruby\log\" -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -like "*build*.log" } | 
            ForEach-Object {
                Write-Output "=== Log file: $($_.FullName) ==="
                Get-Content $_.FullName -Tail 200
            }
            
        throw "Chef build failed. See logs for details."
    }
}

function Upload-BuildkiteArtifact {
    [CmdletBinding()]
    param()
    
    try {
        Write-Output "--- Uploading package to BuildKite"
        C:\buildkite-agent\bin\buildkite-agent.exe artifact upload "C:\omnibus-ruby\chef\pkg\*.msi*" 
        if ( -not $? ) { throw "Failed to upload artifact to BuildKite" }
    }
    catch {
        Write-Error "Failed to upload artifact: $_"
        exit 1
    }
}

function Publish-ToArtifactory {
    [CmdletBinding()]
    param()
    
    try {
        if ($env:BUILDKITE_ORGANIZATION_SLUG -ne "chef-oss") {
            Write-Output "--- Setting up Gem API Key"
            $env:GEM_HOST_API_KEY = "Basic ${env:ARTIFACTORY_API_KEY}"

            Write-Output "--- Publishing package to Artifactory"
            bundle exec ruby "${ScriptDir}/omnibus_chef_publish.rb"
            if ( -not $? ) { throw "Chef publish failed" }
        }
        else {
            Write-Output "--- Skipping Artifactory publish for chef-oss organization"
        }
    }
    catch {
        Write-Error "Failed to publish to Artifactory: $_"
        exit 1
    }
}

# Main execution block
try {
    Initialize-ProgressSigning
    Initialize-Environment
    
    Install-ChefFoundation
    Install-OmnibusDependencies
    
    Build-ChefPackage
    Sign-ChefPackage
    
    Upload-BuildkiteArtifact
    Publish-ToArtifactory
    
    Write-Output "Chef build and signing completed successfully"
    exit 0
}
catch {
    Write-Error "Chef build pipeline failed: $_"
    exit 1
}