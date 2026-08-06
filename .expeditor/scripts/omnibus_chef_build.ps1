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
    if (-not ([string]::IsNullOrWhiteSpace($env:AZURE_TENANT_ID) -and `
              [string]::IsNullOrWhiteSpace($env:AZURE_CLIENT_ID) -and `
              [string]::IsNullOrWhiteSpace($env:AZURE_CLIENT_SECRET))) {
        Write-Output "[OK] Azure credentials pre-initialized (from pre-command hook)"
    } else {
        # BEST PRACTICE: Fetch credentials directly inside Docker container using EC2 IAM role
        # This is more secure than passing via environment variables from the host
        Write-Output "Azure credentials not pre-initialized; fetching from Akeyless inside container..."
        
        try {
            # Fetch AWS credentials from EC2 metadata service (available inside Docker)
            # This uses the IAM role attached to the EC2 instance
            Write-Output "Fetching AWS credentials from EC2 metadata service..."
            $TOKEN = Invoke-WebRequest -Uri "http://169.254.169.254/latest/api/token" `
                -Headers @{"X-aws-ec2-metadata-token-ttl-seconds" = "21600"} `
                -UseBasicParsing | Select-Object -ExpandProperty Content
            
            $ROLE = Invoke-WebRequest -Uri "http://169.254.169.254/latest/meta-data/iam/security-credentials/" `
                -Headers @{"X-aws-ec2-metadata-token" = $TOKEN} `
                -UseBasicParsing | Select-Object -ExpandProperty Content
            
            $RESPONSE = Invoke-WebRequest -Uri "http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE" `
                -Headers @{"X-aws-ec2-metadata-token" = $TOKEN} `
                -UseBasicParsing | Select-Object -ExpandProperty Content | ConvertFrom-Json
            
            # Set AWS credentials temporarily for aws CLI calls
            $env:AWS_ACCESS_KEY_ID = $RESPONSE.AccessKeyId
            $env:AWS_SECRET_ACCESS_KEY = $RESPONSE.SecretAccessKey
            $env:AWS_SESSION_TOKEN = $RESPONSE.Token
            
            # Fetch Akeyless access ID from AWS Parameter Store
            Write-Output "Fetching AKEYLESS_ACCESS_ID from Parameter Store..."
            $awsRegion = if ($env:AWS_REGION) { $env:AWS_REGION } else { "us-west-2" }
            
            # Use PowerShell to call aws CLI (pre-installed in container)
            $accessIdOutput = & aws ssm get-parameter `
                --name "buildkite-akeyless-access-id" `
                --with-decryption `
                --region $awsRegion `
                --query "Parameter.Value" `
                --output text 2>&1
            
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to fetch Akeyless access ID from Parameter Store: $accessIdOutput"
            }
            
            $env:AKEYLESS_ACCESS_ID = $accessIdOutput.Trim()
            
            # Fetch Azure credentials from Akeyless dynamic secret
            Write-Output "Authenticating to Akeyless and fetching Azure credentials..."
            $AkeylessExe = "$env:USERPROFILE\.akeyless\bin\akeyless.exe"
            
            if (-not (Test-Path $AkeylessExe)) {
                throw "Akeyless CLI not found at $AkeylessExe"
            }
            
            # Authenticate to Akeyless via AWS IAM
            $authOutput = & $AkeylessExe auth --access-id $env:AKEYLESS_ACCESS_ID --access-type aws_iam 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                throw "Akeyless auth failed: $authOutput"
            }
            
            # Extract token
            $tokenMatch = $authOutput | Select-String -Pattern 'Token:\s+(\S+)'
            if (-not $tokenMatch) {
                throw "Could not extract Akeyless token from auth output"
            }
            $token = $tokenMatch.Matches[0].Groups[1].Value
            
            # Fetch dynamic secret with Azure credentials
            $dsOutput = & $AkeylessExe dynamic-secret get-value --name "/DevOps/EvCodeSign/evcodesignservice" --token $token 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to fetch Akeyless dynamic secret: $dsOutput"
            }
            
            # Parse credentials
            $ds = $dsOutput | ConvertFrom-Json
            $dsData = if ($ds.secret) { $ds.secret } else { $ds }
            
            if ([string]::IsNullOrWhiteSpace($dsData.tenantId) -or `
                [string]::IsNullOrWhiteSpace($dsData.appId) -or `
                [string]::IsNullOrWhiteSpace($dsData.secretText)) {
                throw "Dynamic secret missing required Azure credentials"
            }
            
            # Set Azure credentials
            $env:AZURE_TENANT_ID = $dsData.tenantId
            $env:AZURE_CLIENT_ID = $dsData.appId
            $env:AZURE_CLIENT_SECRET = $dsData.secretText
            
            Write-Output "[OK] Azure credentials fetched from Akeyless inside container"
            
            # SECURITY: Clear sensitive variables after use
            $token = $null
            $authOutput = $null
            $dsOutput = $null
            
        } catch {
            Write-Error "Failed to fetch Azure credentials: $_"
            exit 1
        }
    }
    
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
        
        # Validate Progress EV certificate (issued by GlobalSign)
        # Progress owns the certificate (Subject), GlobalSign issued it (Issuer)
        if ($sig.SignerCertificate.Issuer -like "*GlobalSign*" -and `
            $sig.SignerCertificate.Issuer -like "*EV*CodeSigning*" -and `
            $sig.SignerCertificate.Subject -like "*PROGRESS*") {
            Write-Output "[OK] Signed with Progress EV certificate (issued by GlobalSign)"
        } else {
            Write-Warning "Certificate validation failed. Expected GlobalSign EV CodeSigning issuer with Progress subject."
            Write-Warning "  Actual Issuer: $($sig.SignerCertificate.Issuer)"
            Write-Warning "  Actual Subject: $($sig.SignerCertificate.Subject)"
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
        
        # Build MSI file URL
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

function Ensure-DotNetRuntime {
    [CmdletBinding()]
    param()

    Write-Output "--- Ensuring .NET 8 runtime is available"
    
    try {
        # Check if dotnet is already available and find its actual location
        $version = dotnet --version 2>&1 | Out-String
        Write-Output "[OK] .NET runtime already available: $version"
        
        # Find actual dotnet location and set DOTNET_ROOT correctly
        # sign.exe uses DOTNET_ROOT to locate the .NET runtime
        $dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
        if ($dotnetCmd) {
            $dotnetPath = $dotnetCmd.Source
            $dotnetDir = Split-Path -Path $dotnetPath -Parent
            Write-Output "Found dotnet at: $dotnetDir"
            $env:DOTNET_ROOT = $dotnetDir
            Write-Output "Set DOTNET_ROOT = $env:DOTNET_ROOT"
        }
        return
    } catch {
        Write-Output "dotnet command not found, will attempt installation"
    }
    
    try {
        # Download and install .NET 8 runtime
        Write-Output "Downloading .NET 8 installer..."
        $dotnetInstallerUrl = "https://dot.net/v1/dotnet-install.ps1"
        $dotnetInstallerPath = "$env:TEMP\dotnet-install.ps1"
        
        Invoke-WebRequest -Uri $dotnetInstallerUrl -OutFile $dotnetInstallerPath -ErrorAction Stop
        
        # Run installer for .NET 8
        Write-Output "Installing .NET 8 runtime..."
        & $dotnetInstallerPath -Version "8.0" -InstallDir "$env:ProgramFiles\dotnet" -NoPath -ErrorAction Stop
        
        # Add to PATH
        $dotnetDir = "$env:ProgramFiles\dotnet"
        if ($env:PATH -notlike "*$dotnetDir*") {
            $env:PATH = "$dotnetDir;$env:PATH"
        }
        
        # Set DOTNET_ROOT for .NET tools
        $env:DOTNET_ROOT = $dotnetDir
        
        # Verify installation
        $version = dotnet --version 2>&1 | Out-String
        Write-Output "[OK] .NET 8 runtime installed: $version"
    }
    catch {
        Write-Warning "Failed to ensure .NET runtime: $_"
        Write-Warning "Continuing anyway - sign tool may fail if .NET is not available"
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

        # Set omnibus-private branch to progress-sign-for-msi (for Progress EV code signing)
        Write-Output "--- Setting omnibus-private branch to progress-sign-for-msi/muthuja"
        $env:OMNIBUS_GITHUB_BRANCH = "progress-sign-for-msi/muthuja"
        Write-Output "  OMNIBUS_GITHUB_BRANCH = $env:OMNIBUS_GITHUB_BRANCH"

        # Ensure .NET 8 runtime is available (needed for sign tool used during MSI packaging)
        Ensure-DotNetRuntime

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
    Ensure-DotNetRuntime
    
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
finally {
    # Clean up sensitive environment variables for security
    Write-Output "--- Cleaning up sensitive environment variables"
    $sensitiveEnvVars = @(
        'AZURE_TENANT_ID',
        'AZURE_CLIENT_ID', 
        'AZURE_CLIENT_SECRET',
        'OMNIBUS_AZURE_KEY_VAULT_URL',
        'OMNIBUS_AZURE_CERT_NAME',
        'AWS_S3_ACCESS_KEY',
        'AWS_S3_SECRET_KEY',
        'ARTIFACTORY_PASSWORD',
        'ARTIFACTORY_API_KEY',
        'GITHUB_TOKEN',
        'GEM_HOST_API_KEY'
    )
    
    foreach ($var in $sensitiveEnvVars) {
        if (Test-Path "env:\$var") {
            Remove-Item -Path "env:\$var" -ErrorAction SilentlyContinue
        }
    }
    
    # Remove .netrc file if it exists
    $netrcPath = "$env:USERPROFILE\_netrc"
    if (Test-Path $netrcPath) {
        Remove-Item $netrcPath -Force -ErrorAction SilentlyContinue
    }
    
    Write-Output "[OK] Cleanup completed"
}