param(
    [string]$NetScalerHost = "vpx01",
    [string]$NetScalerUser = "nsroot",
    [string]$NetScalerPassword = "nsr00t",
    [string]$CoreLogicPrefix = "VS_CL1009"
)

function Invoke-NitroApi ($resourceType, $resourceName = $null, $method = 'Get', $body = $null) {
    $uri = if ($null -ne $resourceName -and $resourceName -ne '') { "$baseUri/$resourceType/$resourceName" } else { "$baseUri/$resourceType" }
    try {
        if ($method -eq 'Post') { return Invoke-RestMethod -Uri $uri -WebSession $session -Method Post -Body $body -ContentType 'application/json' }
        return Invoke-RestMethod -Uri $uri -WebSession $session -Method Get
    }
    catch {
        Write-Warning "Nitro API $method failed for ${uri}: $_"
        return $null
    }
}

function Get-NitroCollection ($response, $propertyName) {
    if (!$response) { return @() }
    if ($response.PSObject.Properties.Name -notcontains $propertyName) { return @() }
    return @($response.$propertyName)
}

function Get-NitroObject ($resourceType, $resourceName, $propertyName = $resourceType) {
    $response = Invoke-NitroApi $resourceType $resourceName
    $items = Get-NitroCollection $response $propertyName
    if ($items.Count -eq 0) { return $null }
    return $items[0]
}

function Get-NitroValues ($response, $propertyName, $fieldName, $excludeValues = @()) {
    $values = @()
    foreach ($item in (Get-NitroCollection $response $propertyName)) {
        if ($item.PSObject.Properties.Name -notcontains $fieldName) { continue }
        $value = $item.$fieldName
        if ($null -eq $value -or $value -eq '') { continue }
        if ($excludeValues -contains $value) { continue }
        $values += $value
    }
    return $values
}

function Get-NitroRecords ($response, $propertyName, $fieldNames) {
    $records = @()
    foreach ($item in (Get-NitroCollection $response $propertyName)) {
        $record = [ordered]@{}
        foreach ($fieldName in $fieldNames) {
            if ($item.PSObject.Properties.Name -notcontains $fieldName) { continue }
            $value = $item.$fieldName
            if ($null -eq $value -or $value -eq '') { continue }
            $record[$fieldName] = $value
        }
        if ($record.Count -gt 0) { $records += [PSCustomObject]$record }
    }
    return $records
}

function Get-BindingValues ($bindingType, $resourceName, $fieldName, $excludeValues = @()) {
    $response = Invoke-NitroApi $bindingType $resourceName
    return , (Get-NitroValues $response $bindingType $fieldName $excludeValues)
}

function Get-BindingRecords ($bindingType, $resourceName, $fieldNames) {
    $response = Invoke-NitroApi $bindingType $resourceName
    return , (Get-NitroRecords $response $bindingType $fieldNames)
}

function Get-UniqueValues ($values) { return @($values | ? { $null -ne $_ -and $_ -ne '' } | Sort-Object -Unique) }

function Save-JsonFile ($path, $object, $depth = 12) { $object | ConvertTo-Json -Depth $depth | Set-Content -Path $path -Encoding UTF8 }

function Export-NitroObject ($resourceName, $resourceType, $targetDirectory, $propertyName = $resourceType) {
    $object = Get-NitroObject $resourceType $resourceName $propertyName
    if (!$object) { Write-Warning "Could not export $resourceType $($resourceName)."; return }
    Save-JsonFile (Join-Path $targetDirectory "$resourceName.json") $object 10
}

function Export-NitroObjects ($resourceNames, $resourceType, $targetDirectory, $propertyName = $resourceType, $excludeNames = @()) {
    foreach ($resourceName in (Get-UniqueValues $resourceNames)) {
        if ($excludeNames -contains $resourceName) { continue }
        Export-NitroObject $resourceName $resourceType $targetDirectory $propertyName
    }
}

function Get-LBvServerDependencies ($vserverName) {
    return [ordered]@{
        ServiceGroups = Get-BindingValues 'lbvserver_servicegroup_binding' $vserverName 'servicegroupname'
        Services      = Get-BindingValues 'lbvserver_service_binding' $vserverName 'servicename'
    }
}

function Get-ResourceDependencies ($resourceType, $resourceName, $defaultMonitors) {
    $dependencies = [ordered]@{
        Servers  = @()
        Monitors = @()
    }
    switch ($resourceType) {
        'servicegroup' {
            $dependencies.Servers = Get-BindingValues 'servicegroup_servicegroupmember_binding' $resourceName 'servername'
            $dependencies.Monitors = Get-BindingValues 'servicegroup_lbmonitor_binding' $resourceName 'monitor_name' $defaultMonitors
        }
        'service' {
            $service = Get-NitroObject 'service' $resourceName 'service'
            if ($service -and $service.servername) { $dependencies.Servers = @($service.servername) }
            $dependencies.Monitors = Get-BindingValues 'service_lbmonitor_binding' $resourceName 'monitor_name' $defaultMonitors
        }
    }
    return $dependencies
}

function Remove-EmptyDirectories ($paths) { foreach ($path in $paths) { if ((dir $path -File -EA 0).Count -eq 0) { del $path -Force -Recurse } } }

# =====================
# Main Script
# =====================
Clear-Host
# Trust all SSL (self-signed)
[System.Net.ServicePointManager]::CheckCertificateRevocationList = { $false }
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$baseUri = "https://$NetScalerHost/nitro/v1/config"

# Login (retrieve session cookie, NetScaler expects {login={...}})
$loginBody = @{ login = @{ username = $NetScalerUser; password = $NetScalerPassword; timeout = '300' } } | ConvertTo-Json
$null = Invoke-RestMethod -Uri "$baseUri/login" -Method Post -Body $loginBody -ContentType 'application/json' -SessionVariable session

$vservers = Get-NitroCollection (Invoke-NitroApi 'lbvserver') 'lbvserver'

$exportDirectory = Join-Path $PSScriptRoot $NetScalerHost
$serversDirectory = Join-Path $exportDirectory 'Servers'
$monitorsDirectory = Join-Path $exportDirectory 'Monitors'
$serviceGroupsDirectory = Join-Path $exportDirectory 'ServiceGroups'
$servicesDirectory = Join-Path $exportDirectory 'Services'

$null = MD $exportDirectory -Force -EA 0
$null = MD $serversDirectory -Force -EA 0
$null = MD $monitorsDirectory -Force -EA 0
$null = MD $serviceGroupsDirectory -Force -EA 0
$null = MD $servicesDirectory -Force -EA 0

$defaultMonitors = @(
    'ping-default', 'tcp-default', 'quic-default', 'kafka-autodiscover', 'arp', 'nd6', 'ping', 'tcp', 'http',
    'tcp-ecv', 'http-ecv', 'udp-ecv', 'dns', 'ftp', 'tcps', 'https', 'tcps-ecv', 'https-ecv', 'xdm', 'xnc',
    'mqtt', 'mqtt-tls', 'http2direct', 'http2ssl', 'dtls', 'ldns-ping', 'ldns-tcp', 'ldns-dns', 'stasecure',
    'sta', 'VPN_INT_MON-0'
)

$allServerNames = @()
$allMonitorNames = @()
$allServiceGroupNames = @()
$allServiceNames = @()

foreach ($vserver in $vservers) {
    if ($vserver.name -like "$CoreLogicPrefix*") { continue }

    $dependencies = Get-LBvServerDependencies $vserver.name
    $vserverExport = $vserver.PSObject.Copy()

    if ($dependencies.ServiceGroups.Count -gt 0) { $vserverExport | Add-Member -MemberType NoteProperty -Name servicegroups -Value $dependencies.ServiceGroups -Force }
    if ($dependencies.Services.Count -gt 0) { $vserverExport | Add-Member -MemberType NoteProperty -Name services -Value $dependencies.Services -Force }

    Save-JsonFile (Join-Path $exportDirectory "$($vserver.name).json") $vserverExport
    $allServiceGroupNames += $dependencies.ServiceGroups
    $allServiceNames += $dependencies.Services
}

foreach ($serviceGroupName in (Get-UniqueValues $allServiceGroupNames)) {
    $serviceGroup = Get-NitroObject 'servicegroup' $serviceGroupName 'servicegroup'
    if (!$serviceGroup) { continue }

    $dependencies = Get-ResourceDependencies 'servicegroup' $serviceGroupName $defaultMonitors
    if ($dependencies.Monitors.Count -gt 0) { $serviceGroup | Add-Member -MemberType NoteProperty -Name monitors -Value $dependencies.Monitors -Force }

    $members = Get-BindingRecords 'servicegroup_servicegroupmember_binding' $serviceGroupName @('servername', 'port', 'weight', 'serverid', 'hashid', 'state')
    if ($members) { $serviceGroup | Add-Member -MemberType NoteProperty -Name servicegroupmember -Value $members -Force }

    Save-JsonFile (Join-Path $serviceGroupsDirectory "$serviceGroupName.json") $serviceGroup
    $allServerNames += $dependencies.Servers
    $allMonitorNames += $dependencies.Monitors
}

foreach ($serviceName in (Get-UniqueValues $allServiceNames)) {
    $service = Get-NitroObject 'service' $serviceName 'service'
    if (!$service) { continue }

    $dependencies = Get-ResourceDependencies 'service' $serviceName $defaultMonitors
    $service | Add-Member -MemberType NoteProperty -Name dependencies -Value $dependencies -Force

    Save-JsonFile (Join-Path $servicesDirectory "$serviceName.json") $service
    $allServerNames += $dependencies.Servers
    $allMonitorNames += $dependencies.Monitors
}

Export-NitroObjects $allServerNames 'server' $serversDirectory 'server'
Export-NitroObjects $allMonitorNames 'lbmonitor' $monitorsDirectory 'lbmonitor' $defaultMonitors

Remove-EmptyDirectories @($serversDirectory, $serviceGroupsDirectory, $servicesDirectory, $monitorsDirectory)

$null = Invoke-NitroApi 'logout' $null 'Post' (ConvertTo-Json @{ logout = @{} })