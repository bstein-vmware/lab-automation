param(
    [Parameter(Mandatory)] [string]$VCenterServer,
    [Parameter(Mandatory)] [string]$LibraryName,
    [Parameter(Mandatory)] [string]$NewSubscriptionUrl,
    [string]$Username,
    [string]$Password
)

$ErrorActionPreference = 'Stop'
$ConfirmPreference     = 'None'

try {
    $connected = $global:DefaultVIServers | Where-Object { $_.Name -eq $VCenterServer -and $_.IsConnected }
    if (-not $connected) {
        Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
        if ($Username -and $Password) {
            Connect-VIServer -Server $VCenterServer -User $Username -Password $Password | Out-Null
        } else {
            Connect-VIServer -Server $VCenterServer | Out-Null
        }
        Write-Host "Connected to $VCenterServer."
    }

    $library = Get-ContentLibrary -Name $LibraryName -Subscribed -ErrorAction SilentlyContinue
    if (-not $library) {
        throw "Content Library '$LibraryName' not found on $VCenterServer."
    }
    # Fetch the SSL thumbprint for the subscription host so Set-ContentLibrary can validate it
    $subUri    = [System.Uri]$NewSubscriptionUrl
    $tcp       = [System.Net.Sockets.TcpClient]::new($subUri.Host, 443)
    $ssl       = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, { $true })
    $ssl.AuthenticateAsClient($subUri.Host)
    $cert      = [System.Security.Cryptography.X509Certificates.X509Certificate2]$ssl.RemoteCertificate
    $thumbprint = [regex]::Replace($cert.Thumbprint, '..(?!$)', '$0:')
    $ssl.Close(); $tcp.Close()

    Write-Host "Updating subscription URL for '$LibraryName'..."
    Write-Host "  Old URL: $($library.SubscriptionUrl)"
    Write-Host "  New URL: $NewSubscriptionUrl"
    Write-Host "  SSL Thumbprint: $thumbprint"

    Set-ContentLibrary -SubscribedContentLibrary $library -SubscriptionUrl $NewSubscriptionUrl -SslThumbprint $thumbprint | Out-Null

    Write-Host "✅ '$LibraryName' subscription URL updated successfully."
}
catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    $inner = $_.Exception
    while ($inner) {
        Write-Host "  → $($inner.Message)" -ForegroundColor Red
        $inner = $inner.InnerException
    }
    exit 1
}
finally {
    Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}
