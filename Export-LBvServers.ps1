# =====================
# Configuratie
# =====================
$NetScalerHost = "vpx01"
$NetScalerUser = "nsroot"
$NetScalerPassword = "nsr00t"
$CoreLogicPrefix = "VS_CL1009"
$baseUri = "https://$NetScalerHost/nitro/v1/config"

# =====================
# Functies
# =====================
function Export-NitroObject ($Names, $Type, $TargetDir, $PropertyName, $Session, $ExcludeNames) {
    $realType = $Type
    $realProperty = $PropertyName
    # Volgens documentatie: monitors zijn altijd 'lbmonitor'
    if ($Type -eq 'monitor' -or $Type -eq 'lbmonitor') {
        $realType = 'lbmonitor'
        $realProperty = 'lbmonitor'
    }
    foreach ($name in $Names) {
        if ($ExcludeNames -and ($ExcludeNames -contains $name)) { continue }
        try {
            $detail = Invoke-RestMethod -Uri "$baseUri/$realType/$name" -WebSession $Session -Method Get
            $path = Join-Path $TargetDir ("$name.json")
            $detail.$realProperty | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
        }
        catch {
            Write-Warning "Kon $realType $name niet exporteren: $_"
        }
    }
}

# Haal alleen ServiceGroups en Services (in volgorde) als dependency op voor LBvServer
function Get-LBvServerDependency ($vserver, $session, $baseUri) {
    $deps = [ordered]@{
        ServiceGroups = @()
        Services      = @()
    }
    $bindings = Invoke-RestMethod -Uri "$baseUri/lbvserver_binding/$($vserver.name)" -WebSession $session -Method Get
    if ($bindings.lbvserver_binding) {
        foreach ($bind in $bindings.lbvserver_binding) {
            if ($bind.lbvserver_servicegroup_binding) {
                foreach ($sg in $bind.lbvserver_servicegroup_binding) {
                    $sgName = $sg.servicegroupname
                    $deps.ServiceGroups += $sgName
                }
            }
            if ($bind.lbvserver_service_binding) {
                foreach ($svc in $bind.lbvserver_service_binding) {
                    $svcName = $svc.servicename
                    $deps.Services += $svcName
                }
            }
        }
    }
    return $deps
}

# Generieke dependency-functie voor ServiceGroup en Service
function Get-ObjectDependency ($type, $name, $session, $baseUri, $defaultMonitors) {
    $deps = [ordered]@{
        Servers  = @()
        Monitors = @()
    }
    if ($type -eq 'servicegroup') {
        $members = Invoke-RestMethod -Uri "$baseUri/servicegroup_servicegroupmember_binding/$name" -WebSession $session -Method Get
        if ($members.servicegroup_servicegroupmember_binding) {
            foreach ($member in $members.servicegroup_servicegroupmember_binding) {
                if ($member.servername) { $deps.Servers += $member.servername }
            }
        }
        $monBindings = Invoke-RestMethod -Uri "$baseUri/servicegroup_lbmonitor_binding/$name" -WebSession $session -Method Get
        if ($monBindings.servicegroup_lbmonitor_binding) {
            foreach ($mon in $monBindings.servicegroup_lbmonitor_binding) {
                $m = $mon.monitor_name
                if ($m -and ($defaultMonitors -notcontains $m)) { $deps.Monitors += $m }
            }
        }
    }
    elseif ($type -eq 'service') {
        $svcDetail = Invoke-RestMethod -Uri "$baseUri/service/$name" -WebSession $session -Method Get
        if ($svcDetail.service.servername) { $deps.Servers += $svcDetail.service.servername }
        $monBindings = Invoke-RestMethod -Uri "$baseUri/service_lbmonitor_binding/$name" -WebSession $session -Method Get
        if ($monBindings.service_lbmonitor_binding) {
            foreach ($mon in $monBindings.service_lbmonitor_binding) {
                $m = $mon.monitor_name
                if ($m -and ($defaultMonitors -notcontains $m)) { $deps.Monitors += $m }
            }
        }
    }
    return $deps
}

# =====================
# Main Script
# =====================
cls
# Trust all SSL (self-signed)
[System.Net.ServicePointManager]::CheckCertificateRevocationList = { $false }
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Login
$loginBody = @{ login = @{ username = $NetScalerUser; password = $NetScalerPassword; timeout = "300" } } | ConvertTo-Json
$null = Invoke-RestMethod -Uri "$baseUri/login" -Method Post -Body $loginBody -ContentType 'application/json' -SessionVariable session

# Get all LB vServers
$vservers = Invoke-RestMethod -Uri "$baseUri/lbvserver" -WebSession $session -Method Get

# Prepare export folders
$exportDir = "$PSScriptRoot\$NetScalerHost"
$serversDir = "$exportDir\Servers"
$monitorsDir = "$exportDir\Monitors"
$ServiceGroupsDir = "$exportDir\ServiceGroups"
$ServicesDir = "$exportDir\Services"
$null = New-Item -Path $exportDir -ItemType Directory -Force -EA 0
$null = New-Item -Path $serversDir -ItemType Directory -Force -EA 0
$null = New-Item -Path $monitorsDir -ItemType Directory -Force -EA 0
$null = New-Item -Path $ServiceGroupsDir -ItemType Directory -Force -EA 0
$null = New-Item -Path $ServicesDir -ItemType Directory -Force -EA 0

# Exclusion list for default monitors
$defaultMonitors = @('ping-default', 'tcp-default', 'quic-default', 'kafka-autodiscover', 'arp', 'nd6', 'ping', 'tcp', 'http', 'tcp-ecv', 'http-ecv', 'udp-ecv', 'dns', 'ftp', 'tcps', 'https', 'tcps-ecv', 'https-ecv', 'xdm', 'xnc', 'mqtt', 'mqtt-tls', 'http2direct', 'http2ssl', 'dtls', 'ldns-ping', 'ldns-tcp', 'ldns-dns', 'stasecure', 'sta', 'VPN_INT_MON-0')

# Collect all dependencies
$allServerNames = @()
$allMonitorNames = @()
$allServiceGroupNames = @()
$allServiceNames = @()

# Verzamel alle unieke ServiceGroups/Services voor latere export
$allServiceGroupNames = @()
$allServiceNames = @()
$allServerNames = @()
$allMonitorNames = @()

foreach ($vserver in $vservers.lbvserver) {
    if ($vserver.name -like "$CoreLogicPrefix*") { continue }
    $deps = Get-LBvServerDependency $vserver $session $baseUri
    $vserverExport = $vserver.PSObject.Copy()
    if ($deps.ServiceGroups.Count -gt 0) { $vserverExport | Add-Member -MemberType NoteProperty -Name servicegroups -Value $deps.ServiceGroups }
    if ($deps.Services.Count -gt 0) { $vserverExport | Add-Member -MemberType NoteProperty -Name services -Value $deps.Services }
    $outputPath = Join-Path -Path $exportDir -ChildPath ("$($vserver.name).json")
    $vserverExport | ConvertTo-Json -Depth 12 | Set-Content -Path $outputPath -Encoding UTF8
    $allServiceGroupNames += $deps.ServiceGroups
    $allServiceNames += $deps.Services
}

# ServiceGroups exporteren met hun eigen dependencies-blok
$allServiceGroupNames = $allServiceGroupNames | Sort-Object -Unique

# ServiceGroups exporteren met dependencies-blok
foreach ($sgName in $allServiceGroupNames) {
    $sgDetail = Invoke-RestMethod -Uri "$baseUri/servicegroup/$sgName" -WebSession $session -Method Get
    $sgExport = $sgDetail.servicegroup
    if ($sgExport -is [System.Collections.IEnumerable] -and $sgExport.Count -gt 0) { $sgExport = $sgExport[0] }
    $sgDeps = Get-ObjectDependency 'servicegroup' $sgName $session $baseUri $defaultMonitors
    # Voeg monitors direct toe als property
    if ($sgDeps.Monitors.Count -gt 0) { $sgExport | Add-Member -MemberType NoteProperty -Name monitors -Value $sgDeps.Monitors -Force }
    # memberport ophalen uit bindings
    $memberBindings = Invoke-RestMethod -Uri "$baseUri/servicegroup_servicegroupmember_binding/$sgName" -WebSession $session -Method Get
    $sgMembers = @()
    if ($memberBindings.servicegroup_servicegroupmember_binding) {
        foreach ($member in $memberBindings.servicegroup_servicegroupmember_binding) {
            $memberObj = [PSCustomObject]@{ servername = $member.servername; port = $member.port }
            if ($member.weight) { $memberObj | Add-Member -MemberType NoteProperty -Name weight -Value $member.weight }
            if ($member.order) { $memberObj | Add-Member -MemberType NoteProperty -Name order -Value $member.order }
            $sgMembers += $memberObj
        }
    }
    if ($sgMembers.Count -gt 0) { $sgExport | Add-Member -MemberType NoteProperty -Name servicegroupmember -Value $sgMembers -Force }
    $outputPath = Join-Path -Path $ServiceGroupsDir -ChildPath ("$sgName.json")
    $sgExport | ConvertTo-Json -Depth 12 | Set-Content -Path $outputPath -Encoding UTF8
    $allServerNames += $sgDeps.Servers
    $allMonitorNames += $sgDeps.Monitors
}

# Services exporteren met dependencies-blok
$allServiceNames = $allServiceNames | Sort-Object -Unique
foreach ($svcName in $allServiceNames) {
    $svcDetail = Invoke-RestMethod -Uri "$baseUri/service/$svcName" -WebSession $session -Method Get
    $svcExport = $svcDetail.service
    $svcDeps = Get-ObjectDependency 'service' $svcName $session $baseUri $defaultMonitors
    $svcExport | Add-Member -MemberType NoteProperty -Name dependencies -Value $svcDeps
    $outputPath = Join-Path -Path $ServicesDir -ChildPath ("$svcName.json")
    $svcExport | ConvertTo-Json -Depth 12 | Set-Content -Path $outputPath -Encoding UTF8
    $allServerNames += $svcDeps.Servers
    $allMonitorNames += $svcDeps.Monitors
}

# Servers en monitors dedupliceren
$allServerNames = $allServerNames | Sort-Object -Unique
$allMonitorNames = $allMonitorNames | Sort-Object -Unique

# Export all objects
Export-NitroObject $allServerNames 'server' $serversDir 'server' $session @()
Export-NitroObject $allMonitorNames 'monitor' $monitorsDir 'monitor' $session $defaultMonitors

# Deduplicate
$allServerNames = $allServerNames | Sort-Object -Unique
$allMonitorNames = $allMonitorNames | Sort-Object -Unique
$allServiceGroupNames = $allServiceGroupNames | Sort-Object -Unique
$allServiceNames = $allServiceNames | Sort-Object -Unique

# Export all objects
Export-NitroObject $allServerNames 'server' $serversDir 'server' $session @()
Export-NitroObject $allMonitorNames 'monitor' $monitorsDir 'monitor' $session $defaultMonitors

# Remove empty folders
foreach ($dir in @($serversDir, $ServiceGroupsDir, $ServicesDir, $monitorsDir)) {
    if ((Get-ChildItem -Path $dir -File -EA 0).Count -eq 0) {
        Remove-Item -Path $dir -Force -Recurse
    }
}

# Logout
$null = Invoke-RestMethod -Uri "$baseUri/logout" -Method Post -Body (ConvertTo-Json @{logout = @{} }) -WebSession $session -ContentType 'application/json'