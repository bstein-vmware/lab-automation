param(
    [Parameter(Mandatory)] [string]$VCenterServer,
    [Parameter(Mandatory)] [string]$Username,
    [Parameter(Mandatory)] [string]$Password,
    [Parameter(Mandatory)] [string]$YamlPath,
    [Parameter(Mandatory)] [string]$ServiceName,
    [Parameter(Mandatory)] [string]$ClusterName,
    [string]$ConfigYamlPath = ""
)

$ErrorActionPreference = 'Stop'
$ConfirmPreference     = 'None'

$sdkVersion = '13.5.0.25380678'
if (-not (Get-Module -ListAvailable -Name VMware.Sdk.vSphere | Where-Object { $_.Version.ToString() -eq $sdkVersion })) {
    Write-Host "Installing VMware.Sdk.vSphere $sdkVersion..."
    Install-Module -Name VMware.Sdk.vSphere -RequiredVersion $sdkVersion -Force -AllowClobber -Scope CurrentUser
    Write-Host "Module installed."
}
Import-Module VMware.Sdk.vSphere -RequiredVersion $sdkVersion -Force

# ---------------------------------------------------------------------------
# Module: VMware.Sdk.vSphere 13.5.0.25380678
# In SDK 9.x the per-subsystem modules (e.g. VMware.Sdk.vSphere.vCenter.NamespaceManagement)
# are stub packages — all cmdlets live in the consolidated VMware.Sdk.vSphere module.
#
# Tier 1 — service definition management (cmdlet names unchanged from 8.x):
#   Invoke-CreateNamespaceManagementSupervisorServices          POST /supervisor-services
#   Invoke-GetSupervisorServiceNamespaceManagement              GET  /supervisor-services/{svc}
#   Invoke-CreateSupervisorServiceNamespaceManagementVersions   POST /supervisor-services/{svc}/versions
#   Invoke-GetSupervisorServiceVersionNamespaceManagement       GET  /supervisor-services/{svc}/versions/{ver}
#
# Tier 2 — install/manage on a Supervisor (Vcenter-prefixed cmdlets, 9.x SDK):
#   Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate  POST /supervisors/{sup}/supervisor-services
#   Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet     GET  /supervisors/{sup}/supervisor-services/{svc}
#   Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesSet     PUT  /supervisors/{sup}/supervisor-services/{svc}
#   Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesList    GET  /supervisors/{sup}/supervisor-services
#
# Precheck (no Vcenter prefix on cmdlet; Vcenter prefix appears only on the spec parameter):
#   Invoke-PrecheckSupervisorSupervisorService                                        POST /supervisors/{sup}/supervisor-services/{svc}?action=precheck
#   Invoke-GetSupervisorSupervisorServiceTargetVersionSupervisorServicesPrecheck      GET  /supervisors/{sup}/supervisor-services/{svc}/versions/{ver}/precheck
# ---------------------------------------------------------------------------

function Get-SupervisorId {
    # In VCF 9.x the Supervisor identifier is a UUID, not the cluster MoRef.
    # Enumerate all supervisors, check each one's topology for the cluster MoRef,
    # and return the matching supervisor ID.
    param([string]$ClusterName)
    $clusterMoRef = (Get-Cluster -Name $ClusterName -ErrorAction Stop).ExtensionData.MoRef.Value
    $summaries = Invoke-ListNamespaceManagementSupervisorsSummaries
    foreach ($item in $summaries.Items) {
        $topo = $null
        try { $topo = Invoke-GetSupervisorNamespaceManagementTopology -Supervisor $item.Supervisor } catch {}
        if ($topo | Where-Object { $_.Clusters -contains $clusterMoRef }) {
            return $item.Supervisor
        }
    }
    throw "No Supervisor found for cluster '$ClusterName' (MoRef: $clusterMoRef). Verify Workload Management is enabled."
}

function Invoke-WithRetry {
    # Retries a scriptblock when the error matches a pattern (e.g. package not yet reconciled).
    param(
        [scriptblock]$Action,
        [string]$RetryPattern = 'not found',
        [string]$Context      = '',
        [int]$RetryCount      = 6,
        [int]$RetryDelaySec   = 20
    )
    for ($i = 1; $i -le $RetryCount; $i++) {
        try {
            & $Action
            return
        } catch {
            if ($_.ToString() -match $RetryPattern -and $i -lt $RetryCount) {
                Write-Host "$Context Retrying in ${RetryDelaySec}s (attempt $i/$RetryCount)..."
                Start-Sleep -Seconds $RetryDelaySec
            } else {
                Write-Error $_ -ErrorAction Stop
            }
        }
    }
}

function Invoke-SupervisorServicePrecheck {
    param([string]$SupervisorId, [string]$ServiceName, [string]$Version)
    Write-Host "[$ServiceName] Initiating precheck for version $Version on supervisor $SupervisorId..."
    $precheckSpec = Initialize-NamespaceManagementSupervisorsSupervisorServicesPrecheckSpec -TargetVersion $Version
    Invoke-PrecheckSupervisorSupervisorService `
        -Supervisor $SupervisorId `
        -SupervisorService $ServiceName `
        -VcenterNamespaceManagementSupervisorsSupervisorServicesPrecheckSpec $precheckSpec | Out-Null
}

function Wait-ForPrecheckSuccess {
    # Status values: SUCCESS, FAILED; absence means still running — poll until terminal.
    param([string]$SupervisorId, [string]$ServiceName, [string]$Version, [int]$TimeoutSec = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $result = $null
        try {
            $result = Invoke-GetSupervisorSupervisorServiceTargetVersionSupervisorServicesPrecheck `
                -Supervisor $SupervisorId `
                -SupervisorService $ServiceName `
                -TargetVersion $Version
        } catch {}
        if ($result) {
            Write-Host "[$ServiceName] Precheck status: $($result.Status)"
            if ($result.Status -eq 'COMPATIBLE') {
                Write-Host "[$ServiceName] Precheck passed."
                return
            }
            if ($result.Status -eq 'INCOMPATIBLE') {
                throw "[$ServiceName] Precheck failed (INCOMPATIBLE): $($result.Errors | Out-String)"
            }
        } else {
            Write-Host "[$ServiceName] Precheck result not yet available, waiting..."
        }
        Start-Sleep -Seconds 15
    }
    throw "[$ServiceName] Timed out waiting for precheck to complete."
}

function Wait-ForVersionActivated {
    param([string]$ServiceName, [string]$Version, [int]$TimeoutSec = 120)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $v = $null
        try { $v = Invoke-GetSupervisorServiceVersionNamespaceManagement -SupervisorService $ServiceName -Version $Version } catch {}
        if ($v -and $v.State -eq "ACTIVATED") {
            Write-Host "[$ServiceName] Version $Version is ACTIVATED."
            return
        }
        Write-Host "[$ServiceName] Waiting for version $Version to activate (state: $($v.State))..."
        Start-Sleep -Seconds 10
    }
    throw "[$ServiceName] Timed out waiting for version $Version to reach ACTIVATED state."
}

Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
Connect-VIServer -Server $VCenterServer -User $Username -Password $Password | Out-Null


$yaml        = Get-Content -Path $YamlPath -Raw
$yamlB64     = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($yaml))
$versionMatches = [regex]::Matches($yaml, '(?m)^\s{2}version:\s*(.+)$')
$version     = $versionMatches[$versionMatches.Count - 1].Groups[1].Value.Trim()
$supervisorId = Get-SupervisorId -ClusterName $ClusterName

Write-Host "[$ServiceName] version=$version  supervisor=$supervisorId"

# --- Tier 1: Register or add version in global catalog (unchanged) ---
$existing = $null
try { $existing = Invoke-GetSupervisorServiceNamespaceManagement -SupervisorService $ServiceName } catch {}

$justActivated = $false
if ($null -eq $existing) {
    Write-Host "[$ServiceName] Not found — registering..."
    $carvelVersionSpec = Initialize-NamespaceManagementSupervisorServicesVersionsCarvelCreateSpec -Content $yamlB64
    $carvelSpec        = Initialize-NamespaceManagementSupervisorServicesCarvelCreateSpec         -VersionSpec $carvelVersionSpec
    $createSpec        = Initialize-NamespaceManagementSupervisorServicesCreateSpec               -CarvelSpec  $carvelSpec
    Invoke-CreateNamespaceManagementSupervisorServices `
        -NamespaceManagementSupervisorServicesCreateSpec $createSpec | Out-Null
    Wait-ForVersionActivated -ServiceName $ServiceName -Version $version
    $justActivated = $true
} else {
    $existingVersion = $null
    try { $existingVersion = Invoke-GetSupervisorServiceVersionNamespaceManagement -SupervisorService $ServiceName -Version $version } catch {}

    if ($null -eq $existingVersion) {
        Write-Host "[$ServiceName] Already registered — adding new version $version..."
        $carvelVersionSpec = Initialize-NamespaceManagementSupervisorServicesVersionsCarvelCreateSpec -Content $yamlB64
        $versionSpec       = Initialize-NamespaceManagementSupervisorServicesVersionsCreateSpec       -CarvelSpec $carvelVersionSpec
        Invoke-CreateSupervisorServiceNamespaceManagementVersions `
            -SupervisorService $ServiceName `
            -NamespaceManagementSupervisorServicesVersionsCreateSpec $versionSpec | Out-Null
        Wait-ForVersionActivated -ServiceName $ServiceName -Version $version
        $justActivated = $true
    } else {
        Write-Host "[$ServiceName] Version $version already exists — skipping."
    }
}

# --- Precheck: must pass before install or upgrade ---
Invoke-SupervisorServicePrecheck -SupervisorId $supervisorId -ServiceName $ServiceName -Version $version
Wait-ForPrecheckSuccess -SupervisorId $supervisorId -ServiceName $ServiceName -Version $version

# --- Tier 2: Install or update on the Supervisor (new API) ---
#
# Spec differences vs. old ClusterSupervisorServices API:
#   OLD CreateSpec: SupervisorService, Version, YamlServiceConfig + Add-Member hack for ignore_warnings
#   NEW CreateSpec: SupervisorService, Version, YamlServiceConfig  (precheck bypass removed from spec)
#   OLD SetSpec:    Version + Add-Member hack
#   NEW SetSpec:    Version, YamlServiceConfig
#   Parameter:      -Cluster (MoRef) → -Supervisor (MoRef, same value)

$onSupervisor = $null
try { $onSupervisor = Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet -Supervisor $supervisorId -SupervisorService $ServiceName } catch {}

if ($null -eq $onSupervisor) {
    Write-Host "[$ServiceName] Installing on supervisor..."
    $installParams = @{
        SupervisorService = $ServiceName
        Version           = $version
    }
    if ($ConfigYamlPath -ne "" -and (Test-Path $ConfigYamlPath)) {
        $installParams["YamlServiceConfig"] = [Convert]::ToBase64String(
            [System.Text.Encoding]::UTF8.GetBytes((Get-Content -Path $ConfigYamlPath -Raw))
        )
    }
    $installSpec = Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec @installParams
    Invoke-WithRetry -Context "[$ServiceName] Carvel package not yet on supervisor." `
                     -RetryPattern 'package\.data\.packaging\.carvel\.dev.*not found' `
                     -Action {
        Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate `
            -Supervisor $supervisorId `
            -VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec $installSpec | Out-Null
    }
} elseif ($onSupervisor.CurrentVersion -eq $version) {
    Write-Host "[$ServiceName] Version $version already installed on supervisor — skipping."
} else {
    Write-Host "[$ServiceName] Already on supervisor — updating from $($onSupervisor.CurrentVersion) to $version..."
    $setSpec = Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesSetSpec -Version $version
    Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesSet `
        -Supervisor $supervisorId `
        -SupervisorService $ServiceName `
        -VcenterNamespaceManagementSupervisorsSupervisorServicesSetSpec $setSpec | Out-Null
}

Write-Host "[$ServiceName] Done."
Disconnect-VIServer -Confirm:$false | Out-Null
