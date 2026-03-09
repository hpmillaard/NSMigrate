param(
    [string]$NetScalerHost = "vpx01",
    [string]$NetScalerUser = "nsroot",
    [string]$NetScalerPassword = "nsr00t",
    [string]$StringMapName = "SM_CL1009_CS_CONTROL",
    [string]$EntryKey,
    [string]$EntryValue,
    [ValidateSet('ANY', 'LAN')][string]$Scope,
    [string]$Url,
    [string]$ContentSwitch,
    [string]$LBvServer,
    [string]$Destination,
    [ValidateSet('301', '302', '307', '308')][string]$ResponseCode,
    [switch]$Force,
    [switch]$PassThru
)

function Show-DialogInput($Title, $Prompt, $Default = '') {
    Add-Type -AssemblyName Microsoft.VisualBasic
    return [Microsoft.VisualBasic.Interaction]::InputBox($Prompt, $Title, $Default)
}

function Show-DialogPopup($Title, $Message, $Buttons = 0, $Icon = 64) {
    $shell = New-Object -ComObject WScript.Shell
    return $shell.Popup($Message, 0, $Title, $Buttons + $Icon)
}

function Select-GridItem($Items, $Title) {
    $selected = $Items | Out-GridView -Title $Title -PassThru
    if (!$selected) { throw "No selection made." }
    return @($selected)[0]
}

function Initialize-NitroSession() {
    [System.Net.ServicePointManager]::CheckCertificateRevocationList = { $false }
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $script:baseUri = "https://$NetScalerHost/nitro/v1/config"
    $loginBody = @{ login = @{ username = $NetScalerUser; password = $NetScalerPassword; timeout = '300' } } | ConvertTo-Json
    $null = Invoke-RestMethod -Uri "$($script:baseUri)/login" -Method Post -Body $loginBody -ContentType 'application/json' -SessionVariable script:session
}

function Close-NitroSession() {
    if ($script:session) {
        $null = Invoke-RestMethod -Uri "$($script:baseUri)/logout" -Method Post -Body (ConvertTo-Json @{ logout = @{} }) -WebSession $script:session -ContentType 'application/json'
    }
}

function Invoke-NitroGet($ResourceType, $ResourceName = $null) {
    $uri = if ($ResourceName) { "$($script:baseUri)/$($ResourceType)/$($ResourceName)" } else { "$($script:baseUri)/$($ResourceType)" }
    try { return Invoke-RestMethod -Uri $uri -WebSession $script:session -Method Get }
    catch {
        Write-Host "Nitro GET failed for $($uri): $($_.Exception.Message)" -F Red
        return $null
    }
}

function Get-NitroCollection($Response, $PropertyName) {
    if (!$Response) { return @() }
    if ($Response.PSObject.Properties.Name -notcontains $PropertyName) { return @() }
    return @($Response.$PropertyName)
}

function Test-ExplicitTrailingSlash($Value) {
    $clean = ($Value -replace '[?#].*$', '').Trim()
    return $clean.EndsWith('/')
}

function Get-UrlContext($InputUrl) {
    if ([string]::IsNullOrWhiteSpace($InputUrl)) { throw 'A URL is required.' }
    $trimmed = $InputUrl.Trim()
    if ($trimmed -notmatch '^https?://') {
        if ($trimmed -match '^[a-zA-Z0-9][a-zA-Z0-9\.-]*(/.*)?$') {
            $trimmed = "https://$($trimmed)"
        }
        else {
            throw 'Invalid URL or hostname.'
        }
    }
    try { $uri = [Uri]$trimmed }
    catch { throw "Invalid URL: $($trimmed)" }
    if (!$uri.IsAbsoluteUri) { throw 'The URL must be absolute.' }
    if ($uri.Scheme -notin @('http', 'https')) { throw 'Only http and https URLs are supported.' }
    $path = [Uri]::UnescapeDataString($uri.AbsolutePath)
    if ($path -eq '/') { $path = '' }
    return [PSCustomObject]@{
        Raw                = $trimmed
        Uri                = $uri
        Scheme             = $uri.Scheme.ToLower()
        Host               = $uri.Host.ToLower()
        Path               = $path
        HostAndPath        = if ($path) { "$($uri.Host.ToLower())$($path.ToLower())" } else { $uri.Host.ToLower() }
        EndsWithSlash      = Test-ExplicitTrailingSlash $trimmed
        HasQueryOrFragment = ($uri.Query -ne '') -or ($uri.Fragment -ne '')
        FirstPathSegment   = if ($path) { @($path.Trim('/') -split '/')[0].ToLower() } else { '' }
        HostLabels         = @($uri.Host.ToLower() -split '\.')
    }
}

function Get-ContentSwitchCandidates($UrlContext) {
    $csvservers = Get-NitroCollection (Invoke-NitroGet 'csvserver') 'csvserver'
    $items = foreach ($cs in $csvservers) {
        $name = [string]$cs.name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $score = 0
        $serviceType = [string]$cs.servicetype
        $domainToken = ''
        $protocolToken = ''
        if ($name -match '^CS_(.+)_(HTTP|SSL)$') {
            $domainToken = $matches[1].ToLower()
            $protocolToken = $matches[2].ToUpper()
        }
        if ($domainToken) {
            if ($UrlContext.Host -eq $domainToken) { $score += 120 }
            elseif ($UrlContext.Host.EndsWith(".$($domainToken)")) { $score += 100 }
            elseif ($UrlContext.Host.Contains($domainToken)) { $score += 60 }
        }
        foreach ($label in $UrlContext.HostLabels) { if ($label -and $name.ToLower().Contains($label)) { $score += 10 } }
        if ($UrlContext.Scheme -eq 'https' -and ($protocolToken -eq 'SSL' -or $serviceType -eq 'SSL')) { $score += 50 }
        if ($UrlContext.Scheme -eq 'http' -and ($protocolToken -eq 'HTTP' -or $serviceType -eq 'HTTP')) { $score += 50 }
        if ($UrlContext.Scheme -eq 'https' -and $protocolToken -eq 'HTTP') { $score -= 10 }
        if ($UrlContext.Scheme -eq 'http' -and $protocolToken -eq 'SSL') { $score -= 10 }
        [PSCustomObject]@{
            Name        = $name
            ServiceType = $serviceType
            IPAddress   = $cs.ipv46
            Port        = $cs.port
            DomainToken = $domainToken
            Score       = $score
        }
    }
    return @($items | Sort-Object -Property @{Expression = 'Score'; Descending = $true }, @{Expression = 'Name'; Descending = $false })
}

function Resolve-ContentSwitch($UrlContext, $RequestedContentSwitch) {
    if ($RequestedContentSwitch) { return $RequestedContentSwitch }
    $candidates = Get-ContentSwitchCandidates $UrlContext
    $ranked = @($candidates | ? { $_.Score -gt 0 })
    if ($ranked.Count -eq 0) { return (Select-GridItem $candidates 'Select the target content switch').Name }
    if ($ranked.Count -eq 1) { return $ranked[0].Name }
    $topScore = $ranked[0].Score
    $top = @($ranked | ? { $_.Score -eq $topScore })
    if ($top.Count -eq 1) { return $top[0].Name }
    return (Select-GridItem $top 'Select the target content switch').Name
}

function Resolve-Scope($RequestedScope) {
    if ($RequestedScope) { return $RequestedScope.ToUpper() }
    $scope = Select-GridItem @(
        [PSCustomObject]@{ Scope = 'ANY'; Description = 'Available from any client' }
        [PSCustomObject]@{ Scope = 'LAN'; Description = 'Available only from LAN clients' }
    ) 'Select client reachability scope'
    return $scope.Scope
}

function Get-LBvServerCandidates($UrlContext, $IncludeRedirect) {
    $lbvservers = Get-NitroCollection (Invoke-NitroGet 'lbvserver') 'lbvserver'
    $items = foreach ($vserver in $lbvservers) {
        $name = [string]$vserver.name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if (!$IncludeRedirect -and $name -like 'VS_CL1009*') { continue }
        $lowerName = $name.ToLower()
        $score = 0
        if ($lowerName.Contains($UrlContext.Host)) { $score += 120 }
        foreach ($label in $UrlContext.HostLabels) { if ($label -and $lowerName.Contains($label)) { $score += 15 } }
        if ($UrlContext.FirstPathSegment -and $lowerName.Contains($UrlContext.FirstPathSegment)) { $score += 25 }
        if ($lowerName.Contains(($UrlContext.HostLabels | Select-Object -Last 2) -join '.')) { $score += 25 }
        [PSCustomObject]@{
            Name        = $name
            ServiceType = $vserver.servicetype
            IPAddress   = $vserver.ipv46
            Port        = $vserver.port
            Score       = $score
        }
    }
    return @($items | Sort-Object -Property @{Expression = 'Score'; Descending = $true }, @{Expression = 'Name'; Descending = $false })
}

function Resolve-RedirectVServer($RequestedLBvServer, $RequestedResponseCode) {
    if ($RequestedLBvServer) { return $RequestedLBvServer }
    $code = if ($RequestedResponseCode) { $RequestedResponseCode } else { Resolve-ResponseCode $null }
    $redirectCandidates = @(
        "VS_CL1009_REDIR_$($code)",
        "VS_CL1009_REDIR_$($code)_SWITCH"
    )
    $lbvservers = Get-NitroCollection (Invoke-NitroGet 'lbvserver') 'lbvserver'
    foreach ($candidate in $redirectCandidates) { if (@($lbvservers | ? { $_.name -eq $candidate }).Count -eq 1) { return [PSCustomObject]@{ Name = $candidate; Code = $code } } }
    $choices = @($lbvservers | ? { $_.name -like "*REDIR*$($code)*" } | % { [PSCustomObject]@{ Name = $_.name; ServiceType = $_.servicetype; Port = $_.port } })
    if (!$choices) { $choices = @($lbvservers | ? { $_.name -like '*REDIR*' } | % { [PSCustomObject]@{ Name = $_.name; ServiceType = $_.servicetype; Port = $_.port } }) }
    $selected = Select-GridItem $choices "Select the redirect LB vServer for HTTP $($code)"
    return [PSCustomObject]@{ Name = $selected.Name; Code = $code }
}

function Resolve-LBvServer($UrlContext, $RequestedLBvServer) {
    if ($RequestedLBvServer) { return $RequestedLBvServer }
    $candidates = Get-LBvServerCandidates $UrlContext $false
    $ranked = @($candidates | ? { $_.Score -gt 0 })
    if ($ranked.Count -eq 1) { return $ranked[0].Name }
    if ($ranked.Count -gt 1 -and $ranked[0].Score -gt $ranked[1].Score) { return $ranked[0].Name }
    $list = if ($ranked.Count -gt 0) { $ranked } else { $candidates }
    return (Select-GridItem $list 'Select the target LB vServer').Name
}

function Resolve-ResponseCode($RequestedResponseCode) {
    if ($RequestedResponseCode) { return $RequestedResponseCode }
    $item = Select-GridItem @(
        [PSCustomObject]@{ Code = '301'; Meaning = 'Moved Permanently' }
        [PSCustomObject]@{ Code = '302'; Meaning = 'Found' }
        [PSCustomObject]@{ Code = '307'; Meaning = 'Temporary Redirect' }
        [PSCustomObject]@{ Code = '308'; Meaning = 'Permanent Redirect' }
    ) 'Select the redirect response code'
    return $item.Code
}

function Resolve-Destination($RequestedDestination, $UrlContext) {
    if ($RequestedDestination) { return $RequestedDestination }
    $default = if ($UrlContext.Path) { $UrlContext.Path } else { '/' }
    $destination = Show-DialogInput 'Redirect destination' 'Enter the redirect destination. This may be a relative or full URL.' $default
    if ([string]::IsNullOrWhiteSpace($destination)) { throw 'A redirect destination is required.' }
    return $destination.Trim()
}

function Normalize-EntryKey($ContentSwitchName, $ResolvedScope, $UrlContext) {
    return "$($ContentSwitchName.ToLower());$($ResolvedScope.ToLower());$($UrlContext.HostAndPath)"
}

function Normalize-EntryKeyFromHostAndPath($ContentSwitchName, $ResolvedScope, $HostAndPath) {
    return "$($ContentSwitchName.ToLower());$($ResolvedScope.ToLower());$($HostAndPath.ToLower())"
}

function Normalize-EntryValue($TargetLBvServer, $ResolvedDestination) {
    $parts = @("vs=$($TargetLBvServer)")
    if ($ResolvedDestination) { $parts += "dst=$($ResolvedDestination)" }
    return ((@($parts | % { $_.Trim().TrimEnd(';') }) -join ';') + ';')
}

function Get-AllContentSwitches() {
    $csvservers = Get-NitroCollection (Invoke-NitroGet 'csvserver') 'csvserver'
    return @(
        $csvservers |
        ? { ![string]::IsNullOrWhiteSpace([string]$_.name) } |
        % {
            $name = [string]$_.name
            $ip = [string]$_.ipv46
            $port = [string]$_.port
            $display = if ($ip -and $port) { "$($name) ($($ip):$($port))" } else { $name }
            [PSCustomObject]@{
                Name    = $name
                Display = $display
            }
        } |
        Sort-Object -Property Name
    )
}

function Get-AllLBvServers() {
    $lbvservers = Get-NitroCollection (Invoke-NitroGet 'lbvserver') 'lbvserver'
    return @($lbvservers | % { [string]$_.name } | ? { ![string]::IsNullOrWhiteSpace($_) -and $_ -notlike 'VS_CL1009*' } | Sort-Object -Unique)
}

function Get-SuggestedContentSwitch($UrlContext) {
    $candidates = Get-ContentSwitchCandidates $UrlContext
    if (!$candidates -or @($candidates).Count -eq 0) { return $null }
    return @($candidates)[0].Name
}

function Get-SuggestedLBvServer($UrlContext) {
    $candidates = Get-LBvServerCandidates $UrlContext $false
    $filteredCandidates = @($candidates | ? { $_.Name -notlike 'VS_CL1009*' })
    if (!$filteredCandidates -or @($filteredCandidates).Count -eq 0) { return $null }
    return @($filteredCandidates)[0].Name
}

function Show-EntryForm($Defaults, $ContentSwitches, $LBvServers) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object Windows.Forms.Form
    $form.Text = 'Create StringMap entries'
    $form.StartPosition = 'CenterScreen'
    $form.Width = 660
    $form.Height = 320
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $font = New-Object Drawing.Font('Segoe UI', 10)
    $form.Font = $font

    $y = 14
    $labelWidth = 145
    $inputLeft = 165
    $inputWidth = 470
    $lineHeight = 28

    function Add-Label($text, $top) {
        $label = New-Object Windows.Forms.Label
        $label.Text = $text
        $label.Left = 12
        $label.Top = $top + 5
        $label.Width = $labelWidth
        $label.Height = 24
        $form.Controls.Add($label)
        return $label
    }

    function Add-TextBox($top, $value) {
        $tb = New-Object Windows.Forms.TextBox
        $tb.Left = $inputLeft
        $tb.Top = $top
        $tb.Width = $inputWidth
        if ($null -ne $value) { $tb.Text = [string]$value }
        $form.Controls.Add($tb)
        return $tb
    }

    function Add-Combo($top, $items, $selectedValue, $allowEmpty = $false) {
        $combo = New-Object Windows.Forms.ComboBox
        $combo.Left = $inputLeft
        $combo.Top = $top
        $combo.Width = $inputWidth
        $combo.DropDownStyle = 'DropDownList'
        if ($allowEmpty) { $null = $combo.Items.Add('') }
        foreach ($item in @($items)) { $null = $combo.Items.Add([string]$item) }
        $select = if ($null -ne $selectedValue) { [string]$selectedValue } else { '' }
        if ($combo.Items.Contains($select)) { $combo.SelectedItem = $select }
        elseif ($combo.Items.Count -gt 0) { $combo.SelectedIndex = 0 }
        $form.Controls.Add($combo)
        return $combo
    }

    $null = Add-Label 'URL' $y
    $txtUrl = Add-TextBox $y $Defaults.Url
    $y += $lineHeight

    $null = Add-Label 'Content Switch' $y
    $cmbCs = New-Object Windows.Forms.ComboBox
    $cmbCs.Left = $inputLeft
    $cmbCs.Top = $y
    $cmbCs.Width = $inputWidth
    $cmbCs.DropDownStyle = 'DropDownList'
    $csDisplayToName = @{}
    foreach ($item in @($ContentSwitches)) {
        $display = if ($item.Display) { [string]$item.Display } else { [string]$item.Name }
        $name = [string]$item.Name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $csDisplayToName[$display] = $name
        $null = $cmbCs.Items.Add($display)
    }
    if ($Defaults.ContentSwitch) {
        $defaultCs = @($ContentSwitches | ? { $_.Name -eq $Defaults.ContentSwitch }) | Select-Object -First 1
        if ($defaultCs) {
            $defaultDisplay = if ($defaultCs.Display) { [string]$defaultCs.Display } else { [string]$defaultCs.Name }
            if ($cmbCs.Items.Contains($defaultDisplay)) { $cmbCs.SelectedItem = $defaultDisplay }
        }
    }
    if ($cmbCs.SelectedIndex -lt 0 -and $cmbCs.Items.Count -gt 0) { $cmbCs.SelectedIndex = 0 }
    $form.Controls.Add($cmbCs)
    $y += $lineHeight

    $null = Add-Label 'LB vServer' $y
    $cmbLb = Add-Combo $y $LBvServers $Defaults.LBvServer
    $y += $lineHeight

    $null = Add-Label 'Scope' $y
    $cmbScope = Add-Combo $y @('ANY', 'LAN') $Defaults.Scope
    $y += $lineHeight

    $null = Add-Label 'Redirect to (optional)' $y
    $txtRedirect = Add-TextBox $y $Defaults.RedirectTo
    $y += $lineHeight

    $lblCode = Add-Label 'Response code' $y
    $cmbCode = Add-Combo $y @('301', '302', '307', '308') $Defaults.ResponseCode $true

    $updateRedirectState = {
        $hasRedirect = ![string]::IsNullOrWhiteSpace($txtRedirect.Text)
        $cmbCode.Visible = $hasRedirect
        $lblCode.Visible = $hasRedirect
        if (!$hasRedirect) {
            $cmbCode.SelectedIndex = 0
        }
        elseif ($cmbCode.SelectedIndex -lt 0 -or [string]::IsNullOrWhiteSpace([string]$cmbCode.SelectedItem)) {
            $cmbCode.SelectedItem = '302'
        }
    }
    $txtRedirect.Add_TextChanged($updateRedirectState)
    & $updateRedirectState

    $hint = New-Object Windows.Forms.Label
    $hint.Left = 12
    $hint.Top = $y + 24
    $hint.Width = 620
    $hint.Height = 34
    $hint.Text = 'When Redirect to is filled in, the script creates an extra redirect entry. Leave it empty for only one direct entry.'
    $form.Controls.Add($hint)

    $btnOk = New-Object Windows.Forms.Button
    $btnOk.Text = 'OK'
    $btnOk.Left = 445
    $btnOk.Top = 248
    $btnOk.Width = 90
    $btnOk.Add_Click({
            if ([string]::IsNullOrWhiteSpace($txtUrl.Text)) {
                $null = [Windows.Forms.MessageBox]::Show('URL is required.', 'Validation', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning)
                return
            }
            if ($cmbCs.SelectedItem -eq $null -or [string]::IsNullOrWhiteSpace([string]$cmbCs.SelectedItem)) {
                $null = [Windows.Forms.MessageBox]::Show('Select a Content Switch.', 'Validation', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning)
                return
            }
            if ($cmbLb.SelectedItem -eq $null -or [string]::IsNullOrWhiteSpace([string]$cmbLb.SelectedItem)) {
                $null = [Windows.Forms.MessageBox]::Show('Select an LB vServer.', 'Validation', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning)
                return
            }
            $form.Tag = [PSCustomObject]@{
                Url           = $txtUrl.Text.Trim()
                ContentSwitch = $csDisplayToName[[string]$cmbCs.SelectedItem]
                LBvServer     = [string]$cmbLb.SelectedItem
                Scope         = [string]$cmbScope.SelectedItem
                ResponseCode  = [string]$cmbCode.SelectedItem
                RedirectTo    = $txtRedirect.Text.Trim()
            }
            $form.DialogResult = [Windows.Forms.DialogResult]::OK
            $form.Close()
        })
    $form.Controls.Add($btnOk)

    $btnCancel = New-Object Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.Left = 545
    $btnCancel.Top = 248
    $btnCancel.Width = 90
    $btnCancel.Add_Click({
            $form.DialogResult = [Windows.Forms.DialogResult]::Cancel
            $form.Close()
        })
    $form.Controls.Add($btnCancel)

    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel

    $result = $form.ShowDialog()
    if ($result -ne [Windows.Forms.DialogResult]::OK) { throw 'Operation cancelled.' }
    return $form.Tag
}

function Resolve-EntryFromParts() {
    $initialUrl = if ($Url) { $Url } else { '' }
    $initialContext = $null
    if ($initialUrl) { $initialContext = Get-UrlContext $initialUrl }

    $allContentSwitches = Get-AllContentSwitches
    $allLBvServers = Get-AllLBvServers

    $defaultContentSwitch = if ($ContentSwitch) { $ContentSwitch } elseif ($initialContext) { Get-SuggestedContentSwitch $initialContext } else { $null }
    $defaultLBvServer = if ($LBvServer) { $LBvServer } elseif ($initialContext) { Get-SuggestedLBvServer $initialContext } else { $null }
    $defaultScope = if ($Scope) { $Scope.ToUpper() } else { 'ANY' }

    $formResult = Show-EntryForm ([PSCustomObject]@{
            Url           = $initialUrl
            ContentSwitch = $defaultContentSwitch
            LBvServer     = $defaultLBvServer
            Scope         = $defaultScope
            ResponseCode  = $ResponseCode
            RedirectTo    = $Destination
        }) $allContentSwitches $allLBvServers

    $urlContext = Get-UrlContext $formResult.Url
    if ($urlContext.HasQueryOrFragment) { Write-Host 'The query string and fragment are ignored when building the StringMap key.' -F Yellow }

    $resolvedContentSwitch = $formResult.ContentSwitch
    $resolvedScope = $formResult.Scope
    $resolvedLBvServer = $formResult.LBvServer
    $resolvedRedirectTo = $formResult.RedirectTo
    $resolvedResponseCode = $formResult.ResponseCode
    $entries = @()

    $entries += [PSCustomObject]@{
        Key          = Normalize-EntryKey $resolvedContentSwitch $resolvedScope $urlContext
        Value        = Normalize-EntryValue $resolvedLBvServer $null
        LBvServer    = $resolvedLBvServer
        ResponseCode = $null
        Destination  = $null
    }

    if ($resolvedRedirectTo) {
        if (!$resolvedResponseCode) { $resolvedResponseCode = '302' }
        $redirect = Resolve-RedirectVServer $null $resolvedResponseCode
        $redirectKeyHostAndPath = if ($urlContext.Path) { $urlContext.Host } elseif ($urlContext.EndsWithSlash) { "$($urlContext.Host)/" } else { "$($urlContext.Host)/" }
        $redirectKey = Normalize-EntryKeyFromHostAndPath $resolvedContentSwitch $resolvedScope $redirectKeyHostAndPath
        if ($redirectKey -notin @($entries | % { $_.Key })) {
            $entries += [PSCustomObject]@{
                Key          = $redirectKey
                Value        = Normalize-EntryValue $redirect.Name $resolvedRedirectTo
                LBvServer    = $redirect.Name
                ResponseCode = $redirect.Code
                Destination  = $resolvedRedirectTo
            }
        }
    }

    return [PSCustomObject]@{
        Url           = $formResult.Url
        StringMap     = $StringMapName
        ContentSwitch = $resolvedContentSwitch
        Scope         = $resolvedScope
        LBvServer     = $entries[0].LBvServer
        ResponseCode  = $entries[0].ResponseCode
        Destination   = $entries[0].Destination
        Entries       = @($entries)
        Keys          = @($entries | % { $_.Key })
        Key           = $entries[0].Key
        Value         = $entries[0].Value
    }
}

function Confirm-Entry($Entry) {
    if ($Force) { return $true }
    $entryList = @($Entry.Entries)
    if ($entryList.Count -eq 0 -and $Entry.Key -and $Entry.Value) {
        $entryList = @([PSCustomObject]@{ Key = $Entry.Key; Value = $Entry.Value; LBvServer = $Entry.LBvServer; ResponseCode = $Entry.ResponseCode; Destination = $Entry.Destination })
    }
    $message = @(
        "StringMap: $($Entry.StringMap)",
        "URL: $($Entry.Url)",
        "Content Switch: $($Entry.ContentSwitch)",
        "Scope: $($Entry.Scope)",
        "Entry count: $($entryList.Count)"
    )
    $index = 1
    foreach ($item in $entryList) {
        $message += "Entry $($index) key: $($item.Key)"
        $message += "Entry $($index) value: $($item.Value)"
        if ($item.ResponseCode) { $message += "Entry $($index) redirect code: $($item.ResponseCode)" }
        if ($item.Destination) { $message += "Entry $($index) destination: $($item.Destination)" }
        $index++
    }
    return (Show-DialogPopup 'Confirm StringMap entry' ($message -join "`r`n") 4 32) -eq 6
}

function Invoke-NitroPostAttempt($Resource, $Body, $ResourceName = $null) {
    $uri = if ($ResourceName) { "$($script:baseUri)/$($Resource)/$($ResourceName)" } else { "$($script:baseUri)/$($Resource)" }
    try {
        $null = Invoke-RestMethod -Uri $uri -WebSession $script:session -Method Post -Body $Body -ContentType 'application/json'
        return [PSCustomObject]@{ Success = $true; Uri = $uri; Message = 'Created' }
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Uri = $uri; Message = $_.Exception.Message }
    }
}

function Add-StringMapBinding($StringMap, $Key, $Value) {
    $attempts = @(
        @{ Resource = 'policystringmap_pattern_binding'; ResourceName = $null; Body = @{ policystringmap_pattern_binding = @{ name = $StringMap; key = $Key; value = $Value } } | ConvertTo-Json -Depth 5 },
        @{ Resource = 'policystringmap_pattern_binding'; ResourceName = $StringMap; Body = @{ policystringmap_pattern_binding = @{ name = $StringMap; key = $Key; value = $Value } } | ConvertTo-Json -Depth 5 },
        @{ Resource = 'policystringmap_binding'; ResourceName = $null; Body = @{ policystringmap_binding = @{ name = $StringMap; key = $Key; value = $Value } } | ConvertTo-Json -Depth 5 },
        @{ Resource = 'policystringmap_binding'; ResourceName = $StringMap; Body = @{ policystringmap_binding = @{ name = $StringMap; key = $Key; value = $Value } } | ConvertTo-Json -Depth 5 }
    )
    foreach ($attempt in $attempts) {
        $result = Invoke-NitroPostAttempt $attempt.Resource $attempt.Body $attempt.ResourceName
        if ($result.Success) { return $result }
        if ($result.Message -match '409') { return [PSCustomObject]@{ Success = $true; Uri = $result.Uri; Message = 'Entry already exists' } }
        Write-Verbose "Nitro POST failed for $($result.Uri): $($result.Message)"
    }
    throw 'Unable to create the StringMap binding through Nitro. Enable -Verbose to inspect the failed attempts.'
}

function Resolve-Entry() {
    if (($EntryKey -and !$EntryValue) -or (!$EntryKey -and $EntryValue)) { throw 'Both EntryKey and EntryValue must be supplied together.' }
    if ($EntryKey -and $EntryValue) {
        $normalizedKey = $EntryKey.Trim().ToLower()
        $normalizedValue = Normalize-EntryValue (($EntryValue -replace '^vs=', '' -replace ';dst=.*$', '').TrimEnd(';')) $null
        return [PSCustomObject]@{
            Url           = $Url
            StringMap     = $StringMapName
            ContentSwitch = $ContentSwitch
            Scope         = $Scope
            LBvServer     = $LBvServer
            ResponseCode  = $ResponseCode
            Destination   = $Destination
            Entries       = @([PSCustomObject]@{ Key = $normalizedKey; Value = $normalizedValue; LBvServer = $LBvServer; ResponseCode = $ResponseCode; Destination = $Destination })
            Keys          = @($normalizedKey)
            Key           = $normalizedKey
            Value         = $normalizedValue
        }
    }
    return Resolve-EntryFromParts
}

Clear-Host
$entry = $null
try {
    Initialize-NitroSession
    $entry = Resolve-Entry
    $entries = @($entry.Entries)
    if ($entries.Count -eq 0 -and $entry.Key -and $entry.Value) {
        $normalizedValue = if ($entry.Value.EndsWith(';')) { $entry.Value } else { "$($entry.Value.TrimEnd(';'));" }
        $entries = @([PSCustomObject]@{ Key = $entry.Key; Value = $normalizedValue; LBvServer = $entry.LBvServer; ResponseCode = $entry.ResponseCode; Destination = $entry.Destination })
    }
    foreach ($item in $entries) { if (!$item.Value.EndsWith(';')) { $item.Value = "$($item.Value.TrimEnd(';'));" } }
    if (!(Confirm-Entry $entry)) { throw 'Operation cancelled.' }
    $createdEntries = @()
    foreach ($item in $entries) {
        $result = Add-StringMapBinding $entry.StringMap $item.Key $item.Value
        $createdEntries += $item
    }
    Write-Host "StringMap entries created on $($NetScalerHost): $(@($createdEntries).Count)." -F Green
    foreach ($item in $createdEntries) {
        Write-Host "Key   : $($item.Key)" -F Green
        Write-Host "Value : $($item.Value)" -F Green
    }
    if ($PassThru) { $entry }
}
catch {
    if ($_.Exception.Message -eq 'Operation cancelled.') { return }
    throw
}
finally {
    Close-NitroSession
}