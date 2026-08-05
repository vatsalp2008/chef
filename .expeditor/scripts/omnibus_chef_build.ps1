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

    Write-Output "Initializing Progress EV code signing credentials"

    # Check if Azure credentials already initialized (from environment)
    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_TENANT_ID) -and `
        -not [string]::IsNullOrWhiteSpace($env:AZURE_CLIENT_ID) -and `
        -not [string]::IsNullOrWhiteSpace($env:AZURE_CLIENT_SECRET)) {
        Write-Output "Azure credentials already initialized"
        if ([string]::IsNullOrWhiteSpace($env:OMNIBUS_AZURE_KEY_VAULT_URL)) {
            $env:OMNIBUS_AZURE_KEY_VAULT_URL = "https://caps-evcodesign-useast.vault.azure.net"
        }
        if ([string]::IsNullOrWhiteSpace($env:OMNIBUS_AZURE_CERT_NAME)) {
            $env:OMNIBUS_AZURE_CERT_NAME = "psc-evcodesign"
        }
        return
    }

    # Fetch credentials from Akeyless (self-contained for Docker builds)
    Write-Output "Fetching Progress EV credentials from Akeyless"
    
    try {
        # Download Akeyless CLI if needed
        if (-not (Test-Path $AkeylessExe)) {
            Write-Output "Downloading Akeyless CLI"
            $AkeylessUrl = "https://akeyless-cli.s3.us-east-2.amazonaws.com/cli/latest/cli-windows-amd64.exe"
            Invoke-WebRequest -Uri $AkeylessUrl -OutFile $AkeylessExe -UseBasicParsing
        }

        # Get AWS region (default to us-west-2 for Parameter Store access)
        $awsRegion = if ($env:AWS_REGION) { $env:AWS_REGION } else { "us-west-2" }

        # Fetch access ID from Parameter Store
        $akeylessAccessId = if ($env:AKEYLESS_ACCESS_ID) {
            $env:AKEYLESS_ACCESS_ID.Trim()
        } else {
            Write-Output "Fetching AKEYLESS_ACCESS_ID from AWS Parameter Store (region: $awsRegion)"
            $paramOutput = aws ssm get-parameter `
                --name "buildkite-akeyless-access-id" `
                --with-decryption `
                --region $awsRegion `
                --query "Parameter.Value" `
                --output text 2>&1
            
            if ($LASTEXITCODE -ne 0) {
                throw "AWS Parameter Store access failed: $paramOutput"
            }
            $paramOutput.Trim()
        }
        
        if ([string]::IsNullOrWhiteSpace($akeylessAccessId)) {
            throw "AKEYLESS_ACCESS_ID is empty"
        }

        # Authenticate to Akeyless using AWS IAM
        Write-Output "Authenticating to Akeyless (aws_iam)"
        $authOutput = & $AkeylessExe auth --access-id $akeylessAccessId --access-type aws_iam 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Akeyless auth failed: $authOutput"
        }
        
        $tokenMatch = $authOutput | Select-String -Pattern 'Token:\s+(\S+)'
        if (-not $tokenMatch) {
            throw "Could not extract Akeyless token from auth response"
        }
        $akeylessToken = $tokenMatch.Matches[0].Groups[1].Value

        # Fetch dynamic secret from Akeyless
        Write-Output "Fetching EV code signing credentials from Akeyless"
        $dsJson = & $AkeylessExe dynamic-secret get-value `
            --name "/DevOps/EvCodeSign/evcodesignservice" `
            --token $akeylessToken 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to fetch dynamic secret: $dsJson"
        }
        
        $ds = ($dsJson | ConvertFrom-Json).secret
        
        if ([string]::IsNullOrWhiteSpace($ds.tenantId) -or `
            [string]::IsNullOrWhiteSpace($ds.appId) -or `
            [string]::IsNullOrWhiteSpace($ds.secretText)) {
            throw "Dynamic secret missing required Azure fields (tenantId, appId, secretText)"
        }

        # Set Azure environment variables for dotnet sign tool
        $env:AZURE_TENANT_ID = $ds.tenantId
        $env:AZURE_CLIENT_ID = $ds.appId
        $env:AZURE_CLIENT_SECRET = $ds.secretText
        $env:OMNIBUS_AZURE_KEY_VAULT_URL = "https://caps-evcodesign-useast.vault.azure.net"
        $env:OMNIBUS_AZURE_CERT_NAME = "psc-evcodesign"
        
        Write-Output "[OK] Azure credentials successfully fetched from Akeyless"
    }
    catch {
        Write-Error "Failed to initialize Progress EV credentials: $_"
        exit 1
    }
}

function Sign-ChefPackage {
    [CmdletBinding()]
    param()
    
    try {
        Write-Output "--- Signing Chef MSI"
        
        $msiPath = Get-ChildItem -Path "C:\omnibus-ruby\chef\pkg\" -Filter *.msi | Select-Object -First 1
        if (-not $msiPath) {
            throw "No MSI file found in C:\omnibus-ruby\chef\pkg\"
        }
        
        $msiPath = $msiPath.FullName
        Write-Output "MSI file: $msiPath"
        
        # Azure login
        Write-Output "Azure login (service principal)"
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            az login --service-principal `
                --username $env:AZURE_CLIENT_ID `
                --password $env:AZURE_CLIENT_SECRET `
                --tenant $env:AZURE_TENANT_ID `
                --output none 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { break }
            if ($attempt -lt 5) {
                Write-Output "  Attempt $attempt/5 failed, retrying in 15s..."
                Start-Sleep -Seconds 15
            }
        }
        if ($LASTEXITCODE -ne 0) {
            throw "az login failed after 5 attempts"
        }
        Write-Output "[OK] Azure login successful"
        
        # Sign MSI using dotnet sign
        Write-Output "Signing with dotnet sign"
        $keyVaultUrl = $env:OMNIBUS_AZURE_KEY_VAULT_URL
        $certificateName = $env:OMNIBUS_AZURE_CERT_NAME
        $timestampServers = @(
            "http://timestamp.acs.microsoft.com/",
            "http://timestamp.globalsign.com/tsa/r45standard",
            "http://ts.ssl.com/",
            "http://timestamp.digicert.com"
        )
        
        $signed = $false
        foreach ($ts in $timestampServers) {
            & sign code azure-key-vault $msiPath `
                -d "Chef Infra Client" `
                -u "https://www.chef.io" `
                -kvu $keyVaultUrl `
                -kvc $certificateName `
                -fd sha256 `
                -td sha256 `
                -t $ts 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Output "[OK] Signed successfully using timestamp server: $ts"
                $signed = $true
                break
            }
            Write-Output "  Timestamp server $ts failed, trying next..."
        }
        
        if (-not $signed) {
            throw "Signing failed with all timestamp servers"
        }
        
        # Verify signature
        Write-Output "Verifying signature"
        $sig = Get-AuthenticodeSignature -FilePath $msiPath
        Write-Output "  Status: $($sig.Status)"
        Write-Output "  Subject: $($sig.SignerCertificate.Subject)"
        Write-Output "  Valid From: $($sig.SignerCertificate.NotBefore)"
        Write-Output "  Valid To: $($sig.SignerCertificate.NotAfter)"
        
        if ($sig.Status -ne 'Valid') {
            throw "Signature verification failed: $($sig.Status)"
        }
        Write-Output "[OK] Signature is valid"
    }
    catch {
        Write-Error "Signing failed: $_"
        exit 1
    }
    finally {
        # Cleanup credentials
        Remove-Item Env:AZURE_TENANT_ID -ErrorAction SilentlyContinue
        Remove-Item Env:AZURE_CLIENT_ID -ErrorAction SilentlyContinue
        Remove-Item Env:AZURE_CLIENT_SECRET -ErrorAction SilentlyContinue
        az logout 2>&1 | Out-Null
        Write-Output "Credentials cleared"
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