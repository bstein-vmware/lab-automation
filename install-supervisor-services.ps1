param(
    [Parameter(Mandatory)] [string]$VCenterServer,
    [Parameter(Mandatory)] [string]$Username,
    [Parameter(Mandatory)] [string]$Password,
    [Parameter(Mandatory)] [string]$YamlPath,
    [Parameter(Mandatory)] [string]$ServiceName,
    [Parameter(Mandatory)] [string]$ClusterName,
    [string]$ConfigYamlPath = ""
)

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

$yaml     = Get-Content -Path $YamlPath -Raw
$yamlB64  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($yaml))
$matches  = [regex]::Matches($yaml, '(?m)^\s{2}version:\s*(.+)$')
$version  = $matches[$matches.Count - 1].Groups[1].Value.Trim()
$clusterId = (Get-Cluster -Name $ClusterName).ExtensionData.MoRef.Value

Write-Host "[$ServiceName] version=$version  cluster=$clusterId"

# --- Register or add version in global catalog ---
$existing = $null
try { $existing = Invoke-GetSupervisorServiceNamespaceManagement -SupervisorService $ServiceName } catch {}

if ($null -eq $existing) {
    Write-Host "[$ServiceName] Not found — registering..."
    $carvelVersionSpec = Initialize-NamespaceManagementSupervisorServicesVersionsCarvelCreateSpec -Content $yamlB64
    $carvelSpec        = Initialize-NamespaceManagementSupervisorServicesCarvelCreateSpec         -VersionSpec $carvelVersionSpec
    $createSpec        = Initialize-NamespaceManagementSupervisorServicesCreateSpec               -CarvelSpec  $carvelSpec
    Invoke-CreateNamespaceManagementSupervisorServices `
        -NamespaceManagementSupervisorServicesCreateSpec $createSpec | Out-Null
    Wait-ForVersionActivated -ServiceName $ServiceName -Version $version
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
    } else {
        Write-Host "[$ServiceName] Version $version already exists — skipping."
    }
}

# --- Install or update on cluster ---
$onCluster = $null
try { $onCluster = Invoke-GetClusterSupervisorServiceNamespaceManagement -Cluster $clusterId -SupervisorService $ServiceName } catch {}

if ($null -eq $onCluster) {
    Write-Host "[$ServiceName] Installing on cluster..."
    $installParams = @{ SupervisorService = $ServiceName; Version = $version }
    if ($ConfigYamlPath -ne "" -and (Test-Path $ConfigYamlPath)) {
        $configB64 = [Convert]::ToBase64String(
            [System.Text.Encoding]::UTF8.GetBytes((Get-Content -Path $ConfigYamlPath -Raw))
        )
        $installParams["YamlServiceConfig"] = $configB64
    }
    $installSpec = Initialize-NamespaceManagementSupervisorServicesClusterSupervisorServicesCreateSpec @installParams
    Invoke-CreateClusterNamespaceManagementSupervisorServices `
        -Cluster $clusterId `
        -NamespaceManagementSupervisorServicesClusterSupervisorServicesCreateSpec $installSpec | Out-Null
} else {
    Write-Host "[$ServiceName] Already on cluster — updating to $version..."
    $setSpec = Initialize-NamespaceManagementSupervisorServicesClusterSupervisorServicesSetSpec -Version $version
    Invoke-SetClusterSupervisorServiceNamespaceManagement `
        -Cluster $clusterId `
        -SupervisorService $ServiceName `
        -NamespaceManagementSupervisorServicesClusterSupervisorServicesSetSpec $setSpec | Out-Null
}

Write-Host "[$ServiceName] Done."
Disconnect-VIServer -Confirm:$false | Out-Null
