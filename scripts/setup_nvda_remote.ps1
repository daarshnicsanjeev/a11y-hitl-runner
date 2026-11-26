[CmdletBinding()]
param(
    [string]$RelayHost = "nvdaremote.com",

    [Parameter(Mandatory = $true)]
    [string]$SessionKey,

    [string]$SetupCmd = "",

    [Parameter(Mandatory = $true)]
    [string]$StartCmd
)

$ErrorActionPreference = "Stop"

function Save-DesktopScreenshot {
    param(
        [string]$OutputPath = (Join-Path $env:TEMP "hitl-final.png")
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose()
        $bitmap.Dispose()
        Write-Host "Saved desktop screenshot to $OutputPath"
    } catch {
        Write-Warning "Failed to capture desktop screenshot: $_"
    }
}

$nvdaUrl = "https://download.nvaccess.org/releases/stable/nvda_2026.3.1.exe"
$installerPath = Join-Path $env:TEMP "nvda_2026.3.1.exe"

Write-Host "Downloading NVDA from $nvdaUrl..."
Invoke-WebRequest -Uri $nvdaUrl -OutFile $installerPath -UseBasicParsing

Write-Host "Installing NVDA silently..."
$installProc = Start-Process -FilePath $installerPath -ArgumentList "--install-silent" -Wait -PassThru -NoNewWindow
if ($installProc.ExitCode -ne 0) {
    throw "NVDA silent installation failed with exit code $($installProc.ExitCode)"
}

Write-Host "Ensuring Windows Audio service (Audiosrv) is running..."
try {
    Set-Service -Name "Audiosrv" -StartupType Automatic -ErrorAction SilentlyContinue
    $audioSvc = Get-Service -Name "Audiosrv" -ErrorAction SilentlyContinue
    if ($audioSvc -and $audioSvc.Status -ne "Running") {
        Start-Service -Name "Audiosrv" -ErrorAction SilentlyContinue
    }
} catch {
    Write-Warning "Could not configure/start Audiosrv: $_"
}

$nvdaConfigDir = Join-Path $env:APPDATA "nvda"
New-Item -ItemType Directory -Force -Path $nvdaConfigDir | Out-Null
$nvdaIniPath = Join-Path $nvdaConfigDir "nvda.ini"

$nvdaIniContent = @"
[remote]
	enabled = True
	[[controlServer]]
		autoconnect = True
		selfHosted = False
		connectionMode = 0
		host = $RelayHost
		key = $SessionKey
"@

Write-Host "Writing NVDA Remote configuration to $nvdaIniPath..."
Set-Content -Path $nvdaIniPath -Value $nvdaIniContent -Encoding UTF8

$nvdaExeCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} "NVDA\nvda.exe"),
    (Join-Path $env:ProgramFiles "NVDA\nvda.exe")
)
$nvdaExe = $nvdaExeCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $nvdaExe) {
    $nvdaExe = "nvda.exe"
}

Write-Host "Starting NVDA ($nvdaExe)..."
Start-Process -FilePath $nvdaExe
Start-Sleep -Seconds 5

$appProc = $null
$targetDir = Join-Path (Get-Location) "target-app"
if (-not (Test-Path $targetDir)) {
    throw "Target directory not found: $targetDir"
}

function Invoke-CheckedStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command
    )
    Write-Host "Running: $Command"
    cmd.exe /c $Command
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("Command failed with exit code ${LASTEXITCODE}: $Command")
        throw "Command failed with exit code ${LASTEXITCODE}: $Command"
    }
}

try {
    Push-Location $targetDir

    if ((Test-Path ".env.example") -and -not (Test-Path ".env")) {
        Write-Host "Copying .env.example to .env..."
        Copy-Item -Path ".env.example" -Destination ".env" -Force
    }

    if (-not [string]::IsNullOrWhiteSpace($SetupCmd)) {
        Write-Host "Running custom setup command..."
        Invoke-CheckedStep -Command $SetupCmd
    } else {
        Write-Host "No SetupCmd provided; auto-detecting ecosystem dependencies in $targetDir..."
        $autoSetupSteps = @()

        if (Test-Path "pnpm-lock.yaml") {
            $autoSetupSteps = @("corepack enable", "pnpm install --frozen-lockfile")
        } elseif (Test-Path "yarn.lock") {
            $autoSetupSteps = @("corepack enable", "yarn install --frozen-lockfile")
        } elseif (Test-Path "package-lock.json") {
            $autoSetupSteps = @("npm ci")
        } elseif (Test-Path "package.json") {
            $autoSetupSteps = @("npm install")
        } elseif (Test-Path "requirements.txt") {
            $autoSetupSteps = @("python -m pip install --upgrade pip", "pip install -r requirements.txt")
        } elseif (Test-Path "pyproject.toml") {
            $autoSetupSteps = @("python -m pip install --upgrade pip", "pip install -e .")
        } elseif ((Get-ChildItem -Filter "*.sln" -ErrorAction SilentlyContinue) -or (Get-ChildItem -Filter "*.csproj" -ErrorAction SilentlyContinue)) {
            $autoSetupSteps = @("dotnet restore", "dotnet build")
        } else {
            Write-Host "No recognized dependency manifest found; skipping auto-install."
        }

        foreach ($step in $autoSetupSteps) {
            Invoke-CheckedStep -Command $step
        }
    }

    if ($StartCmd -match '^https?://') {
        Write-Host "Launching URL maximized in Microsoft Edge: $StartCmd"
        Start-Process -FilePath "msedge.exe" -ArgumentList "--start-maximized", $StartCmd
    } else {
        Write-Host "Starting target command: $StartCmd"
        $portsBefore = (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LocalPort -Unique)
        $appProc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $StartCmd -PassThru

        # Wait briefly for a local server port to open, then launch Edge maximized if one is detected
        $detectedPort = $null
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 2
            $portsNow = (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LocalPort -Unique)
            $newPorts = $portsNow | Where-Object { $_ -notin $portsBefore -and $_ -ge 1024 }
            if ($newPorts) {
                $detectedPort = ($newPorts | Select-Object -First 1)
                break
            }
            if ($appProc.HasExited) {
                break
            }
        }

        if ($detectedPort) {
            $localUrl = "http://localhost:$detectedPort"
            Write-Host "Detected local port $detectedPort; opening $localUrl maximized in Microsoft Edge..."
            Start-Process -FilePath "msedge.exe" -ArgumentList "--start-maximized", $localUrl
        }
    }

    Pop-Location

    Write-Host "=== READY FOR NVDA REMOTE CONNECTION ==="

    while ($true) {
        Start-Sleep -Seconds 10
    }
}
finally {
    Save-DesktopScreenshot
    if ($appProc -and -not $appProc.HasExited) {
        Stop-Process -Id $appProc.Id -Force -ErrorAction SilentlyContinue
    }
}
