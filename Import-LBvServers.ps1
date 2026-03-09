param([switch]$Debug)
# =====================
# Configuratie
# =====================
$NetScalerHost = "vpx01"
$NetScalerUser = "nsroot"
$NetScalerPassword = "nsr00t"
$baseUri = "https://$NetScalerHost/nitro/v1/config"

# =====================
# Functies
# =====================
# Generieke property filter
function Filter-Properties($json, $fields) {
    $filtered = @{}
    foreach ($f in $fields) {
        if ($json.PSObject.Properties.Name -contains $f -and $null -ne $json.$f -and $json.$f -ne "") {
            $filtered[$f] = $json.$f
        }
    }
    return [PSCustomObject]$filtered
}

function Filter-ServerFields($json) {
    $fields = 'name', 'ipaddress', 'state', 'comment', 'domain' # td, ipv6address, domainresolveretry zijn zelden nodig
    return Filter-Properties $json $fields
}

function Filter-MonitorFields($json) {
    $fields = 'monitorname', 'type', 'interval', 'resptimeout', 'retries', 'destip', 'destport', 'state', 'secure', 'httprequest', 'respcode', 'send', 'recv', 'transparent', 'reverse', 'lrtm', 'deviation', 'failureretries', 'alertretries', 'successretries', 'downtime', 'username', 'password', 'domain', 'ipaddress', 'hostname', 'netprofile', 'units1', 'units2', 'units3', 'units4' # kernvelden + units
    return Filter-Properties $json $fields
}

function Filter-ServiceGroupFields($json) {
    $fields = 'servicegroupname', 'servicetype', 'clttimeout', 'svrtimeout', 'state', 'healthmonitor', 'appflowlog', 'maxclient', 'maxreq', 'cacheable', 'usip', 'pathmonitor', 'pathmonitorindv', 'useproxyport', 'cka', 'tcpb', 'cmp', 'downstateflush', 'autoscale', 'netprofile' # memberport, cip, cipheader, sp, rtspsessionidremap, maxbandwidth, monconnectionclose, nodefaultbindings zijn zelden nodig
    return Filter-Properties $json $fields
}

function Filter-LBvServerFields($json) {
    $fields = 'name', 'servicetype', 'ipv46', 'ipset', 'port', 'state', 'lbmethod', 'persistencebackup', 'persistencetype', 'timeout', 'clttimeout', 'cacheable', 'redirurl', 'backupvserver', 'disableprimaryondown', 'downstateflush', 'tcpprofilename', 'httpprofilename', 'comment', 'netprofile', 'appflowlog', 'td', 'authentication', 'authnprofile', 'sopersistence', 'sopersistencetimeout', 'somethod', 'sothreshold', 'sobackupaction', 'healththreshold', 'minautoscalemembers', 'maxautoscalemembers' # kernvelden, rest optioneel
    return Filter-Properties $json $fields
}

function Invoke-NitroApi ($Uri, $Body, $Type, $Action = 'import', $Session = $null) {
    if ($Debug) {
        Write-Host "[DEBUG] URL: $Uri" -ForegroundColor Cyan
        Write-Host "[DEBUG] BODY: $Body" -ForegroundColor Cyan
    }
    try {
        $null = Invoke-RestMethod -Uri $Uri -WebSession $Session -Method Post -Body $Body -ContentType 'application/json'
        if ($Action -eq 'import') {
            Write-Host ("Imported {0}" -f $Type) -ForegroundColor Green
        }
        elseif ($Action -eq 'binding') {
            Write-Host ("Binding toegevoegd: {0}" -f $Type) -ForegroundColor Green
        }
    }
    catch {
        if ($_.Exception.Message -match "409") {
            Write-Host ("CONFLICT bij {0}: {1}" -f $Type, $_.Exception.Message) -ForegroundColor Yellow
        }
        elseif ($_.Exception.Message -match "404") {
            Write-Host ("NIET GEVONDEN bij {0}: {1}" -f $Type, $_.Exception.Message) -ForegroundColor Red
        }
        else {
            Write-Host ("FOUT bij {0}: {1}" -f $Type, $_.Exception.Message) -ForegroundColor Red
        }
    }
}

# Verzamel alle unieke servers en monitors uit ServiceGroups en Services
function Get-AllDependencies($neededServiceGroups, $neededServices, $serviceGroupsDir, $svcDir) {
    $allServers = @{}
    $allMonitors = @{}
    foreach ($sgName in $neededServiceGroups) {
        $sgFile = Join-Path $serviceGroupsDir "$sgName.json"
        if (Test-Path $sgFile) {
            $sgJson = Get-Content -Path $sgFile -Raw | ConvertFrom-Json
            if ($sgJson.servicegroupmember) {
                foreach ($member in $sgJson.servicegroupmember) {
                    if ($member.servername) { $allServers[$member.servername] = $true }
                }
            }
            if ($sgJson.monitors) {
                foreach ($mon in $sgJson.monitors) { $allMonitors[$mon] = $true }
            }
        }
    }
    foreach ($svcName in $neededServices) {
        $svcFile = Get-ChildItem -Path $svcDir -Filter "$svcName.json" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($svcFile) {
            $svcJson = Get-Content -Path $svcFile.FullName -Raw | ConvertFrom-Json
            if ($svcJson.Servers) { foreach ($s in $svcJson.Servers) { $allServers[$s] = $true } }
            elseif ($svcJson.servername) { $allServers[$svcJson.servername] = $true }
            if ($svcJson.Monitors) { foreach ($m in $svcJson.Monitors) { $allMonitors[$m] = $true } }
        }
    }
    return @{ Servers = $allServers; Monitors = $allMonitors }
}

# Genereer een servicegroup-object uit een service-json
function Generate-ServiceGroupFromService($svcJson) {
    $sgName = "SG_$($svcJson.name)"
    $sgObj = [PSCustomObject]@{
        servicegroupname   = $sgName
        servicetype        = $svcJson.servicetype
        clttimeout         = $svcJson.clttimeout
        svrtimeout         = $svcJson.svrtimeout
        state              = $svcJson.state
        healthmonitor      = $svcJson.healthmonitor
        servicegroupmember = @()
        monitors           = @()
    }
    if ($svcJson.Servers) {
        foreach ($srv in $svcJson.Servers) {
            $sgObj.servicegroupmember += [PSCustomObject]@{ servername = $srv; port = $svcJson.port }
        }
    }
    elseif ($svcJson.servername) {
        $sgObj.servicegroupmember += [PSCustomObject]@{ servername = $svcJson.servername; port = $svcJson.port }
    }
    if ($svcJson.Monitors) {
        foreach ($mon in $svcJson.Monitors) { $sgObj.monitors += $mon }
    }
    return $sgObj
}

function Import-NitroObjectByName($folder, $type, $property, $names, $session) {
    foreach ($name in $names.Keys) {
        $file = Get-ChildItem -Path $folder -Filter "$name.json" -EA 0 | Select-Object -First 1
        if ($file) {
            $json = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
            switch ($type) {
                'server' { $filtered = Filter-ServerFields $json }
                'lbmonitor' { $filtered = Filter-MonitorFields $json }
                'servicegroup' { $filtered = Filter-ServiceGroupFields $json }
                default { $filtered = $json }
            }
            $body = @{ $property = $filtered } | ConvertTo-Json -Depth 10
            Invoke-NitroApi -Uri "$baseUri/$type" -Body $body -Type $type -Session $session
        }
        else {
            Write-Output ("Bestand niet gevonden voor {0}: {1}" -f $type, $name)
        }
    }
}

function Restore-ServiceGroupMembers($serviceGroupName, $importRoot, $session) {
    $sgMemberFile = Join-Path (Join-Path $importRoot 'ServiceGroups') "$serviceGroupName.json"
    if (-not (Test-Path $sgMemberFile)) { return }
    $sgJson = Get-Content -Path $sgMemberFile -Raw | ConvertFrom-Json
    $members = @()
    if ($sgJson.servicegroupmember) {
        foreach ($member in $sgJson.servicegroupmember) {
            $memberObj = [PSCustomObject]@{ servername = $member.servername; port = $member.port }
            if ($member.weight) { $memberObj | Add-Member -MemberType NoteProperty -Name weight -Value $member.weight }
            if ($member.order) { $memberObj | Add-Member -MemberType NoteProperty -Name order -Value $member.order }
            $members += $memberObj
        }
    }
    if ($members.Count -gt 0) {
        foreach ($member in $members) {
            $body = @{ servicegroup_servicegroupmember_binding = @{ servicegroupname = $serviceGroupName; servername = $member.servername; port = $member.port } } | ConvertTo-Json
            Invoke-NitroApi -Uri "$baseUri/servicegroup_servicegroupmember_binding" -Body $body -Type "$serviceGroupName -> $($member.servername):$($member.port)" -Action 'binding' -Session $session
        }
    }
    else {
        Write-Host ("GEEN servicegroupmembers gevonden voor $serviceGroupName (geen binding aangemaakt)") -ForegroundColor Yellow
    }
}

function Restore-ServiceGroupMonitorBinding($serviceGroupName, $importRoot, $session) {
    $sgFile = Join-Path (Join-Path $importRoot 'ServiceGroups') "$serviceGroupName.json"
    if (-not (Test-Path $sgFile)) { return }
    $sgJson = Get-Content -Path $sgFile -Raw | ConvertFrom-Json
    $monitors = @()
    if ($sgJson.monitors) { $monitors = $sgJson.monitors }
    if ($monitors.Count -gt 0) {
        foreach ($mon in $monitors) {
            $body = @{ servicegroup_lbmonitor_binding = @{ servicegroupname = $serviceGroupName; monitor_name = $mon } } | ConvertTo-Json
            Invoke-NitroApi -Uri "$baseUri/servicegroup_lbmonitor_binding" -Body $body -Type "$serviceGroupName -> $($mon)" -Action 'binding' -Session $session
        }
    }
    else {
        Write-Host ("GEEN monitors gevonden voor $serviceGroupName (geen binding aangemaakt)") -ForegroundColor Yellow
    }
}

function Restore-VServerServiceGroupBinding($vserverJson, $importRoot, $session) {
    if ($vserverJson.ServiceGroups) {
        foreach ($sg in $vserverJson.ServiceGroups) {
            $body = @{ lbvserver_servicegroup_binding = @{ name = $vserverJson.name; servicegroupname = $sg } } | ConvertTo-Json
            Invoke-NitroApi -Uri "$baseUri/lbvserver_servicegroup_binding" -Body $body -Type "$($vserverJson.name) -> $($sg)" -Action 'binding' -Session $session
        }
    }
    else {
        Write-Host ("GEEN servicegroups gevonden voor $($vserverJson.name) (geen binding aangemaakt)") -ForegroundColor Yellow
    }
}

# =====================
# Main Script
# =====================
cls
# Trust all SSL (self-signed)
[System.Net.ServicePointManager]::CheckCertificateRevocationList = { $false }
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Login (session cookie ophalen, NetScaler verwacht {login={...}})
$loginBody = @{ login = @{ username = $NetScalerUser; password = $NetScalerPassword; timeout = "300" } } | ConvertTo-Json
$loginResponse = Invoke-RestMethod -Uri "$baseUri/login" -Method Post -Body $loginBody -ContentType 'application/json' -SessionVariable session

# 1. Zoek alle *.json bestanden in de hoofdmap en 1e subfolder-niveau (maar niet dieper)
$jsonFiles = dir $PSScriptRoot\*.json -Recurse | ? { ($_.DirectoryName -eq $PSScriptRoot) -or ($_.Directory.Parent -and $_.Directory.Parent.FullName -eq $PSScriptRoot) }
if (-not $jsonFiles) { Write-Output "Geen JSON-bestanden gevonden."; exit }

# 2. Toon Out-GridView met NetScaler (submap) en vServer naam (zonder .json)
Write-Host "Selecteer vServers om te importeren" -ForegroundColor Cyan
$vserverGrid = $jsonFiles | Where-Object { $_.Directory.Parent -and $_.Directory.Parent.FullName -eq $PSScriptRoot } | ForEach-Object { [PSCustomObject]@{NetScaler = $_.Directory.Name; vServer = $_.BaseName } }
$selectedGrid = $vserverGrid | Out-GridView -Title "select vServers to import" -PassThru
if (-not $selectedGrid) { Write-Output "Geen selectie gemaakt. Stoppen."; exit }

# Mapping van NetScaler+vServer naar file object
$fileMap = @{} 
foreach ($f in $jsonFiles) {
    if ($f.Directory.Parent -and $f.Directory.Parent.FullName -eq $PSScriptRoot) {
        $key = "$($f.Directory.Name)|$($f.BaseName)"
        $fileMap[$key] = $f
    }
}

foreach ($row in $selectedGrid) {
    $key = "$($row.NetScaler)|$($row.vServer)"
    $file = $fileMap[$key]
    if (-not $file) { Write-Host "Kan bestand niet vinden voor selectie: $key" -ForegroundColor Red; continue }
    $json = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
    $importRoot = $file.DirectoryName
    $serviceGroupsDir = Join-Path $importRoot 'ServiceGroups'
    $svcDir = Join-Path $importRoot 'Services'

    # Verzamel ServiceGroups en Services uit de vServer JSON
    $neededServiceGroups = @()
    $neededServices = @()
    if ($json.ServiceGroups) { $neededServiceGroups += $json.ServiceGroups }
    if ($json.Services) { $neededServices += $json.Services }

    # Verzamel alle unieke servers en monitors
    $deps = Get-AllDependencies $neededServiceGroups $neededServices $serviceGroupsDir $svcDir
    $serversDir = Join-Path $importRoot 'Servers'
    $monitorsDir = Join-Path $importRoot 'Monitors'
    Import-NitroObjectByName $serversDir 'server' 'server' $deps.Servers $session
    Import-NitroObjectByName $monitorsDir 'lbmonitor' 'lbmonitor' $deps.Monitors $session

    # Importeer de LB vServer zelf vóór de bindings
    $filteredLB = Filter-LBvServerFields $json
    $vserverBody = @{ lbvserver = $filteredLB } | ConvertTo-Json -Depth 10
    Invoke-NitroApi -Uri "$baseUri/lbvserver" -Body $vserverBody -Type "lbvserver" -Session $session

    # Importeer alle ServiceGroups
    foreach ($sgName in $neededServiceGroups) {
        $sgHash = @{$sgName = $true }
        Import-NitroObjectByName $serviceGroupsDir 'servicegroup' 'servicegroup' $sgHash $session
        Restore-ServiceGroupMembers $sgName $importRoot $session
        Restore-ServiceGroupMonitorBinding $sgName $importRoot $session
    }

    # Importeer alle Services als ServiceGroup
    foreach ($svcName in $neededServices) {
        $svcFile = Get-ChildItem -Path $svcDir -Filter "$svcName.json" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($svcFile) {
            $svcJson = Get-Content -Path $svcFile.FullName -Raw | ConvertFrom-Json
            $sgObj = Generate-ServiceGroupFromService $svcJson
            $sgName = $sgObj.servicegroupname
            # Debug: toon het object vóór filteren
            if ($Debug) {
                Write-Host "[DEBUG] SG-object vóór filteren: $(($sgObj | ConvertTo-Json -Depth 10))" -ForegroundColor Cyan
            }
            $sgFiltered = Filter-ServiceGroupFields $sgObj
            if ($sgObj.servicegroupmember) { $sgFiltered | Add-Member -MemberType NoteProperty -Name servicegroupmember -Value $sgObj.servicegroupmember }
            if ($sgObj.monitors) { $sgFiltered | Add-Member -MemberType NoteProperty -Name monitors -Value $sgObj.monitors }
            if ($Debug) {
                Write-Host "[DEBUG] SG-object na filteren: $(($sgFiltered | ConvertTo-Json -Depth 10))" -ForegroundColor Cyan
            }
            $tmpSGFile = Join-Path $serviceGroupsDir "$sgName.json"
            $sgFiltered | ConvertTo-Json -Depth 10 | Set-Content -Path $tmpSGFile -Encoding UTF8
            $tmpSGHash = @{$sgName = $true }
            Import-NitroObjectByName $serviceGroupsDir 'servicegroup' 'servicegroup' $tmpSGHash $session
            Restore-ServiceGroupMembers $sgName $importRoot $session
            Restore-ServiceGroupMonitorBinding $sgName $importRoot $session
        }
        else {
            Write-Host "Service-bestand niet gevonden voor $svcName" -ForegroundColor Red
        }
    }

    # Bindings
    $json.ServiceGroups = $neededServiceGroups
    Restore-VServerServiceGroupBinding $json $importRoot $session
}

# Logout
$null = Invoke-RestMethod -Uri "$baseUri/logout" -Method Post -Body (ConvertTo-Json @{logout = @{} }) -WebSession $session -ContentType 'application/json'