param(
    [string]$NetScalerHost = "vpx01",
    [string]$NetScalerUser = "nsroot",
    [string]$NetScalerPassword = "nsr00t"
)

function Filter-Properties($json, $fields) {
    $filtered = @{}
    foreach ($f in $fields) {
        if ($json.PSObject.Properties.Name -contains $f -and $null -ne $json.$f -and $json.$f -ne "") { $filtered[$f] = $json.$f }
    }
    return [PSCustomObject]$filtered
}

function Filter-ServerFields($json) {
    $fields = 'name', 'ipaddress', 'state', 'comment', 'domain'
    return Filter-Properties $json $fields
}

function Filter-MonitorFields($json) {
    $fields = 'monitorname', 'type', 'interval', 'resptimeout', 'retries', 'destip', 'destport', 'state', 'secure', 'httprequest', 'respcode', 'send', 'recv', 'transparent', 'reverse', 'lrtm', 'deviation', 'failureretries', 'alertretries', 'successretries', 'downtime', 'username', 'password', 'domain', 'ipaddress', 'hostname', 'netprofile', 'units1', 'units2', 'units3', 'units4'
    return Filter-Properties $json $fields
}

function Filter-ServiceGroupFields($json) {
    $fields = 'servicegroupname', 'servicetype', 'clttimeout', 'svrtimeout', 'state', 'healthmonitor', 'appflowlog', 'maxclient', 'maxreq', 'cacheable', 'usip', 'pathmonitor', 'pathmonitorindv', 'useproxyport', 'cka', 'tcpb', 'cmp', 'downstateflush', 'autoscale', 'netprofile'
    return Filter-Properties $json $fields
}

function Filter-LBvServerFields($json) {
    $fields = 'name', 'servicetype', 'ipv46', 'ipset', 'port', 'state', 'lbmethod', 'persistencebackup', 'persistencetype', 'timeout', 'clttimeout', 'cacheable', 'redirurl', 'backupvserver', 'disableprimaryondown', 'downstateflush', 'tcpprofilename', 'httpprofilename', 'comment', 'netprofile', 'appflowlog', 'td', 'authentication', 'authnprofile', 'sopersistence', 'sopersistencetimeout', 'somethod', 'sothreshold', 'sobackupaction', 'healththreshold', 'minautoscalemembers', 'maxautoscalemembers'
    return Filter-Properties $json $fields
}

function Invoke-NitroApi ($Uri, $Body, $Type, $Action = 'import', $Session = $null) {
    Write-Verbose "[DEBUG] URL: $Uri"
    Write-Verbose "[DEBUG] BODY: $Body"
    try {
        $null = Invoke-RestMethod -Uri $Uri -WebSession $Session -Method Post -Body $Body -ContentType 'application/json'
        if ($Action -eq 'import') { Write-Host ("Imported {0}" -f $Type) -F Green }
        elseif ($Action -eq 'binding') { Write-Host ("Binding added: {0}" -f $Type) -F Green }
    }
    catch {
        if ($_.Exception.Message -match "409") { Write-Host ("CONFLICT for {0}: {1}" -f $Type, $_.Exception.Message) -F Yellow }
        elseif ($_.Exception.Message -match "404") { Write-Host ("NOT FOUND for {0}: {1}" -f $Type, $_.Exception.Message) -F Red }
        else { Write-Host ("ERROR for {0}: {1}" -f $Type, $_.Exception.Message) -F Red }
    }
}

function Get-AllDependencies($neededServiceGroups, $neededServices, $serviceGroupsDir, $svcDir) {
    $allServers = @{}
    $allMonitors = @{}
    foreach ($sgName in $neededServiceGroups) {
        $sgFile = Join-Path $serviceGroupsDir "$sgName.json"
        if (Test-Path $sgFile) {
            $sgJson = Get-Content -Path $sgFile -Raw | ConvertFrom-Json
            if ($sgJson.servicegroupmember) {
                foreach ($member in $sgJson.servicegroupmember) { if ($member.servername) { $allServers[$member.servername] = $true } }
            }
            if ($sgJson.monitors) { foreach ($mon in $sgJson.monitors) { $allMonitors[$mon] = $true } }
        }
    }
    foreach ($svcName in $neededServices) {
        $svcFile = Get-ChildItem -Path $svcDir -Filter "$svcName.json" -EA 0 | Select-Object -First 1
        if ($svcFile) {
            $svcJson = Get-Content -Path $svcFile.FullName -Raw | ConvertFrom-Json
            if ($svcJson.Servers) { foreach ($s in $svcJson.Servers) { $allServers[$s] = $true } }
            elseif ($svcJson.servername) { $allServers[$svcJson.servername] = $true }
            if ($svcJson.Monitors) { foreach ($m in $svcJson.Monitors) { $allMonitors[$m] = $true } }
        }
    }
    return @{ Servers = $allServers; Monitors = $allMonitors }
}

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
    if ($svcJson.Servers) { foreach ($srv in $svcJson.Servers) { $sgObj.servicegroupmember += [PSCustomObject]@{ servername = $srv; port = $svcJson.port } } }
    elseif ($svcJson.servername) { $sgObj.servicegroupmember += [PSCustomObject]@{ servername = $svcJson.servername; port = $svcJson.port } }
    if ($svcJson.Monitors) { foreach ($mon in $svcJson.Monitors) { $sgObj.monitors += $mon } }
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
        else { Write-Output ("File not found for {0}: {1}" -f $type, $name) }
    }
}

function Restore-ServiceGroupMembers($serviceGroupName, $importRoot, $session) {
    $sgMemberFile = Join-Path (Join-Path $importRoot 'ServiceGroups') "$serviceGroupName.json"
    if (!(Test-Path $sgMemberFile)) { return }
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
    else { Write-Host ("NO servicegroupmembers found for $serviceGroupName (no binding created)") -F Yellow }
}

function Restore-ServiceGroupMonitorBinding($serviceGroupName, $importRoot, $session) {
    $sgFile = Join-Path (Join-Path $importRoot 'ServiceGroups') "$serviceGroupName.json"
    if (!(Test-Path $sgFile)) { return }
    $sgJson = Get-Content -Path $sgFile -Raw | ConvertFrom-Json
    $monitors = @()
    if ($sgJson.monitors) { $monitors = $sgJson.monitors }
    if ($monitors.Count -gt 0) {
        foreach ($mon in $monitors) {
            $body = @{ servicegroup_lbmonitor_binding = @{ servicegroupname = $serviceGroupName; monitor_name = $mon } } | ConvertTo-Json
            Invoke-NitroApi -Uri "$baseUri/servicegroup_lbmonitor_binding" -Body $body -Type "$serviceGroupName -> $($mon)" -Action 'binding' -Session $session
        }
    }
    else { Write-Host ("NO monitors found for $serviceGroupName (no binding created)") -F Yellow }
}

function Restore-VServerServiceGroupBinding($vserverJson, $importRoot, $session) {
    if ($vserverJson.ServiceGroups) {
        foreach ($sg in $vserverJson.ServiceGroups) {
            $body = @{ lbvserver_servicegroup_binding = @{ name = $vserverJson.name; servicegroupname = $sg } } | ConvertTo-Json
            Invoke-NitroApi -Uri "$baseUri/lbvserver_servicegroup_binding" -Body $body -Type "$($vserverJson.name) -> $($sg)" -Action 'binding' -Session $session
        }
    }
    else { Write-Host ("NO servicegroups found for $($vserverJson.name) (no binding created)") -F Yellow }
}

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
$loginBody = @{ login = @{ username = $NetScalerUser; password = $NetScalerPassword; timeout = "300" } } | ConvertTo-Json
$null = Invoke-RestMethod -Uri "$baseUri/login" -Method Post -Body $loginBody -ContentType 'application/json' -SessionVariable session

# Find all *.json files in the root and first subfolder level (not deeper)
$jsonFiles = Get-ChildItem -Path "$PSScriptRoot\*.json" -Recurse | ? { ($_.DirectoryName -eq $PSScriptRoot) -or ($_.Directory.Parent -and $_.Directory.Parent.FullName -eq $PSScriptRoot) }
if (!$jsonFiles) { Write-Output "No JSON files found."; exit }

# Show Out-GridView with NetScaler (subfolder) and vServer name (without .json)
Write-Host "Select vServers to import" -F Green
$vserverGrid = $jsonFiles | ? { $_.Directory.Parent -and $_.Directory.Parent.FullName -eq $PSScriptRoot } | % { [PSCustomObject]@{NetScaler = $_.Directory.Name; vServer = $_.BaseName } }
$selectedGrid = $vserverGrid | Out-GridView -Title "select vServers to import" -PassThru
if (!$selectedGrid) { Write-Output "No selection made. Stopping."; exit }

# Map NetScaler+vServer to file object
$fileMap = @{} 
foreach ($f in $jsonFiles) { if ($f.Directory.Parent -and $f.Directory.Parent.FullName -eq $PSScriptRoot) { $key = "$($f.Directory.Name)|$($f.BaseName)"; $fileMap[$key] = $f } }
foreach ($row in $selectedGrid) {
    $key = "$($row.NetScaler)|$($row.vServer)"
    $file = $fileMap[$key]
    if (!$file) { Write-Host "Cannot find file for selection: $key" -F Red; continue }
    $json = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
    $importRoot = $file.DirectoryName
    $serviceGroupsDir = Join-Path $importRoot 'ServiceGroups'
    $svcDir = Join-Path $importRoot 'Services'

    # Collect ServiceGroups and Services from the vServer JSON
    $neededServiceGroups = @()
    $neededServices = @()
    if ($json.ServiceGroups) { $neededServiceGroups += $json.ServiceGroups }
    if ($json.Services) { $neededServices += $json.Services }

    # Collect all unique servers and monitors
    $deps = Get-AllDependencies $neededServiceGroups $neededServices $serviceGroupsDir $svcDir
    $serversDir = Join-Path $importRoot 'Servers'
    $monitorsDir = Join-Path $importRoot 'Monitors'
    Import-NitroObjectByName $serversDir 'server' 'server' $deps.Servers $session
    Import-NitroObjectByName $monitorsDir 'lbmonitor' 'lbmonitor' $deps.Monitors $session

    # Import the LB vServer itself before the bindings
    $filteredLB = Filter-LBvServerFields $json
    $vserverBody = @{ lbvserver = $filteredLB } | ConvertTo-Json -Depth 10
    Invoke-NitroApi -Uri "$baseUri/lbvserver" -Body $vserverBody -Type "lbvserver" -Session $session

    # Import all ServiceGroups
    foreach ($sgName in $neededServiceGroups) {
        $sgHash = @{$sgName = $true }
        Import-NitroObjectByName $serviceGroupsDir 'servicegroup' 'servicegroup' $sgHash $session
        Restore-ServiceGroupMembers $sgName $importRoot $session
        Restore-ServiceGroupMonitorBinding $sgName $importRoot $session
    }

    # Import all Services as ServiceGroup
    foreach ($svcName in $neededServices) {
        $svcFile = Get-ChildItem -Path $svcDir -Filter "$svcName.json" -EA 0 | Select-Object -First 1
        if ($svcFile) {
            $svcJson = Get-Content -Path $svcFile.FullName -Raw | ConvertFrom-Json
            $sgObj = Generate-ServiceGroupFromService $svcJson
            $sgName = $sgObj.servicegroupname
            # Debug: show the object before filtering
            Write-Verbose "[DEBUG] SG object before filtering: $(($sgObj | ConvertTo-Json -Depth 10))"
            $sgFiltered = Filter-ServiceGroupFields $sgObj
            if ($sgObj.servicegroupmember) { $sgFiltered | Add-Member -MemberType NoteProperty -Name servicegroupmember -Value $sgObj.servicegroupmember }
            if ($sgObj.monitors) { $sgFiltered | Add-Member -MemberType NoteProperty -Name monitors -Value $sgObj.monitors }
            Write-Verbose "[DEBUG] SG object after filtering: $(($sgFiltered | ConvertTo-Json -Depth 10))"
            $tmpSGFile = Join-Path $serviceGroupsDir "$sgName.json"
            $sgFiltered | ConvertTo-Json -Depth 10 | Set-Content -Path $tmpSGFile -Encoding UTF8
            $tmpSGHash = @{$sgName = $true }
            Import-NitroObjectByName $serviceGroupsDir 'servicegroup' 'servicegroup' $tmpSGHash $session
            Restore-ServiceGroupMembers $sgName $importRoot $session
            Restore-ServiceGroupMonitorBinding $sgName $importRoot $session
        }
        else { Write-Host "Service file not found for $svcName" -F Red }
    }

    # Bindings
    $json.ServiceGroups = $neededServiceGroups
    Restore-VServerServiceGroupBinding $json $importRoot $session
}

# Logout
$null = Invoke-RestMethod -Uri "$baseUri/logout" -Method Post -Body (ConvertTo-Json @{logout = @{} }) -WebSession $session -ContentType 'application/json'