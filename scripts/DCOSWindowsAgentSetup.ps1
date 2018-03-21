[CmdletBinding(DefaultParameterSetName="Standard")]
Param(
    [ValidateNotNullOrEmpty()]
    [string]$MasterIP,
    [ValidateNotNullOrEmpty()]
    [string]$AgentPrivateIP,
    [ValidateNotNullOrEmpty()]
    [string]$BootstrapUrl,
    [AllowNull()]
    [switch]$isPublic = $false,
    [AllowNull()]
    [string]$MesosDownloadDir,
    [AllowNull()]
    [string]$MesosInstallDir,
    [AllowNull()]
    [string]$MesosLaunchDir,
    [AllowNull()]
    [string]$MesosWorkDir,
    [AllowNull()]
    [string]$customAttrs
)

$ErrorActionPreference = "Stop"

$SCRIPTS_REPO_URL = "https://github.com/dcos/dcos-windows"
$SCRIPTS_DIR = Join-Path $env:TEMP "dcos-windows"
$MESOS_BINARIES_URL = "$BootstrapUrl/mesos.zip"
$DIAGNOSTICS_BINARIES_URL = "$BootstrapUrl/diagnostics.zip"
$METRICS_BINARIES_URL = "$BootstrapUrl/metrics.zip"

function Add-ToSystemPath {
    Param(
        [Parameter(Mandatory=$true)]
        [string[]]$Path
    )
    $systemPath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine').Split(';')
    $currentPath = $env:PATH.Split(';')
    foreach($p in $Path) {
        if($p -notin $systemPath) {
            $systemPath += $p
        }
        if($p -notin $currentPath) {
            $currentPath += $p
        }
    }
    $env:PATH = $currentPath -join ';'
    setx.exe /M PATH ($systemPath -join ';')
    if($LASTEXITCODE) {
        Throw "Failed to set the new system path"
    }
}

function Start-ExecuteWithRetry {
    Param(
        [Parameter(Mandatory=$true)]
        [Alias("Command")]
        [ScriptBlock]$ScriptBlock,
        [int]$MaxRetryCount=10,
        [int]$RetryInterval=3,
        [array]$ArgumentList=@()
    )
    $currentErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $retryCount = 0
    while ($true) {
        try {
            $res = Invoke-Command -ScriptBlock $ScriptBlock `
                                  -ArgumentList $ArgumentList
            $ErrorActionPreference = $currentErrorActionPreference
            return $res
        } catch [System.Exception] {
            $retryCount++
            if ($retryCount -gt $MaxRetryCount) {
                $ErrorActionPreference = $currentErrorActionPreference
                Throw
            } else {
                Start-Sleep $RetryInterval
            }
        }
    }
}

function Install-Git {
    $gitInstallerURL = "http://dcos-win.westus.cloudapp.azure.com/downloads/Git-2.14.1-64-bit.exe"
    $gitInstallDir = Join-Path $env:ProgramFiles "Git"
    $gitPaths = @("$gitInstallDir\cmd", "$gitInstallDir\bin")
    if(Test-Path $gitInstallDir) {
        Write-Output "Git is already installed"
        Add-ToSystemPath $gitPaths
        return
    }
    Write-Output "Downloading Git from $gitInstallerURL"
    $programFile = Join-Path $env:TEMP "git.exe"
    Start-ExecuteWithRetry { Invoke-WebRequest -UseBasicParsing -Uri $gitInstallerURL -OutFile $programFile }
    $parameters = @{
        'FilePath' = $programFile
        'ArgumentList' = @("/SILENT")
        'Wait' = $true
        'PassThru' = $true
    }
    Write-Output "Installing Git"
    $p = Start-Process @parameters
    if($p.ExitCode -ne 0) {
        Throw "Failed to install Git during the environment setup"
    }
    Add-ToSystemPath $gitPaths
}

function New-ScriptsDirectory {
    if(Test-Path $SCRIPTS_DIR) {
        Remove-Item -Recurse -Force -Path $SCRIPTS_DIR
    }
    Install-Git
    $p = Start-ExecuteWithRetry { Start-Process -FilePath 'git.exe' -Wait -PassThru -NoNewWindow -ArgumentList @('clone', $SCRIPTS_REPO_URL, $SCRIPTS_DIR) }
    if($p.ExitCode -ne 0) {
        Throw "Failed to clone $SCRIPTS_REPO_URL repository"
    }
}

function Get-MasterIPs {
    [string[]]$ips = ConvertFrom-Json $MasterIP
    # NOTE(ibalutoiu): ACS-Engine adds the Zookeper port to every master IP and we need only the address
    [string[]]$masterIPs = $ips | ForEach-Object { $_.Split(':')[0] }
    return $masterIPs
}

function Install-MesosAgent {
    $masterIPs = Get-MasterIPs
    & "$SCRIPTS_DIR\scripts\mesos-agent-setup.ps1" -MasterAddress $masterIPs -MesosWindowsBinariesURL $MESOS_BINARIES_URL `
                                                -AgentPrivateIP $AgentPrivateIP -Public:$isPublic -CustomAttributes $customAttrs
    if($LASTEXITCODE) {
        Throw "Failed to setup the DCOS Mesos Windows slave agent"
    }
}

function Install-ErlangRuntime {
    & "$SCRIPTS_DIR\scripts\erlang-setup.ps1"
    if($LASTEXITCODE) {
        Throw "Failed to setup the Windows Erlang runtime"
    }
}

function Install-EPMDAgent {
    & "$SCRIPTS_DIR\scripts\epmd-agent-setup.ps1"
    if($LASTEXITCODE) {
        Throw "Failed to setup the DCOS EPMD Windows agent"
    }
}

function Install-SpartanAgent {
    $masterIPs = Get-MasterIPs
    & "$SCRIPTS_DIR\scripts\spartan-agent-setup.ps1" -MasterAddress $masterIPs -AgentPrivateIP $AgentPrivateIP -Public:$isPublic
    if($LASTEXITCODE) {
        Throw "Failed to setup the DCOS Spartan Windows agent"
    }
}

function Install-AdminRouterAgent {
    & "$SCRIPTS_DIR\scripts\adminrouter-agent-setup.ps1" -AgentPrivateIP $AgentPrivateIP
    if($LASTEXITCODE) {
        Throw "Failed to setup the DCOS AdminRouter Windows agent"
    }
}

function Install-DiagnosticsAgent {
    & "$SCRIPTS_DIR\scripts\diagnostics-agent-setup.ps1" -DiagnosticsWindowsBinariesURL $DIAGNOSTICS_BINARIES_URL
    if($LASTEXITCODE) {
        Throw "Failed to setup the DCOS Diagnostics Windows agent"
    }
}

function Install-MetricsAgent {
    & "$SCRIPTS_DIR\scripts\metrics-agent-setup.ps1" -MetricsWindowsBinariesURL $METRICS_BINARIES_URL
    if($LASTEXITCODE) {
        Throw "Failed to setup the DCOS Metrics Windows agent"
    }
}

function Update-Docker {
    $dockerHome = Join-Path $env:ProgramFiles "Docker"
    $baseUrl = "http://dcos-win.westus.cloudapp.azure.com/downloads/docker"
    $version = "18.02.0-ce"
    Stop-Service "Docker"
    Start-ExecuteWithRetry { Invoke-WebRequest -UseBasicParsing -Uri "${baseUrl}/${version}/docker.exe" -OutFile "${dockerHome}\docker.exe" }
    Start-ExecuteWithRetry { Invoke-WebRequest -UseBasicParsing -Uri "${baseUrl}/${version}/dockerd.exe" -OutFile "${dockerHome}\dockerd.exe" }
    Start-Service "Docker"
}

function New-DockerNATNetwork {
    #
    # This needs to be used by all the containers since DCOS Spartan DNS server
    # is not bound to the gateway address.
    # The Docker gateway address is added to the DNS server list unless
    # disable_gatewaydns network option is enabled.
    #
    docker.exe network create --driver="nat" --opt "com.docker.network.windowsshim.disable_gatewaydns=true" "customnat"
    if($LASTEXITCODE -ne 0) {
        Throw "Failed to create the new Docker NAT network with disable_gatewaydns flag"
    }
}

function Get-DCOSVersion {
    $masterIPs = Get-MasterIPs
    $timeout = 7200.0
    $startTime = Get-Date
    while(((Get-Date) - $startTime).TotalSeconds -lt $timeout) {
        foreach($ip in $masterIPs) {
            try {
                $response = Invoke-WebRequest -UseBasicParsing -Uri "http://$ip/dcos-metadata/dcos-version.json"
            } catch {
                continue
            }
            return (ConvertFrom-Json -InputObject $response.Content).version
        }
        Start-Sleep -Seconds 30
    }
    Throw "ERROR: Cannot find the DC/OS version from any of the masters $($masterIPs -join ', ') within a timeout of $timeout seconds"
}

function New-DCOSEnvironmentFile {
    . "$SCRIPTS_DIR\scripts\variables.ps1"
    if(!(Test-Path -Path $DCOS_DIR)) {
        New-Item -ItemType "Directory" -Path $DCOS_DIR
    }
    $envFile = Join-Path $DCOS_DIR "environment"
    $masterIPs = Get-MasterIPs
    Write-Output "Trying to find the DC/OS version by querying the API of the masters: $($masterIPs -join ', ')"
    $dcosVersion = Get-DCOSVersion
    Set-Content -Path $envFile -Value @(
        "PROVIDER=azure",
        "DCOS_VERSION=${dcosVersion}"
    )
}

function New-DCOSServiceWrapper {
    . "$SCRIPTS_DIR\scripts\variables.ps1"
    $parent = Split-Path -Parent -Path $SERVICE_WRAPPER
    if(!(Test-Path -Path $parent)) {
        New-Item -ItemType "Directory" -Path $parent
    }
    Start-ExecuteWithRetry { Invoke-WebRequest -UseBasicParsing -Uri $SERVICE_WRAPPER_URL -OutFile $SERVICE_WRAPPER }
}


try {
    New-ScriptsDirectory
    Update-Docker
    New-DockerNATNetwork
    New-DCOSEnvironmentFile
    New-DCOSServiceWrapper
    Install-MesosAgent
    Install-ErlangRuntime
    Install-EPMDAgent
    Install-SpartanAgent
    Install-AdminRouterAgent
    Install-MetricsAgent

    # To get collect a complete list of services for node health monitoring,
    # the Diagnostics needs always to be the last one to install
    Install-DiagnosticsAgent
} catch {
    Write-Output $_.ToString()
    exit 1
}
Write-Output "Successfully finished setting up the DCOS Windows Agent"
exit 0
