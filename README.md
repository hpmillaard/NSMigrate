# NSMigrate

NSMigrate is a set of PowerShell scripts for exporting and importing Citrix ADC / NetScaler load balancing vServer configurations together with their dependencies.

## Scripts

- **Export-LBvServers.ps1**: Exports LB vServers, ServiceGroups, Services, Servers, and custom monitors to JSON files.
- **Import-LBvServers.ps1**: Imports a previously exported set and restores the relevant bindings.
- **Create-SMEntries.ps1**: Creates CoreLogic `SM_CL1009_CS_CONTROL` StringMap entries interactively or from arguments and submits them through Nitro.

## How It Works

### Export

The export script collects, per LB vServer:

- bound ServiceGroups
- bound Services
- backend Servers
- custom monitors

LB vServers whose names start with the configured CoreLogic prefix are skipped. The default prefix is `VS_CL1009`.

The export is written to a folder named after the NetScaler host, using this structure:

```text
<script folder>\<NetScalerHost>\
<script folder>\<NetScalerHost>\Servers\
<script folder>\<NetScalerHost>\Monitors\
<script folder>\<NetScalerHost>\ServiceGroups\
<script folder>\<NetScalerHost>\Services\
```

### Import

The import script reads JSON files from the script folder and shows the discovered vServers through `Out-GridView`, so you can choose which ones to import.

It then:

- imports the required Servers
- imports the required Monitors
- imports the LB vServer itself
- imports ServiceGroups
- restores ServiceGroup member bindings
- restores monitor bindings on ServiceGroups
- converts standalone Services into temporary ServiceGroup objects when needed
- restores LB vServer to ServiceGroup bindings

## Usage

### Export

```powershell
.\Export-LBvServers.ps1 `
   -NetScalerHost vpx01 `
   -NetScalerUser nsroot `
   -NetScalerPassword nsr00t `
   -CoreLogicPrefix VS_CL1009
```

Parameters:

- `NetScalerHost`: Hostname or IP address of the Citrix ADC / NetScaler appliance
- `NetScalerUser`: Username for the Nitro API
- `NetScalerPassword`: Password for the Nitro API

### Create StringMap Entry

```powershell
.\Create-SMEntries.ps1 `
   -NetScalerHost vpx01 `
   -NetScalerUser nsroot `
   -NetScalerPassword nsr00t
```

Interactive behavior:

- opens a compact GUI with these fields:
  - `URL`
  - `Content Switch` (shown as `Name (IP:Port)`)
  - `LB vServer`
  - `Scope` (`ANY` or `LAN`)
  - `Redirect to (optional)`
  - `Response code` (only visible when `Redirect to` has a value)
- accepts both full URLs and hostnames as URL input (for example `printer.millaard.nl`)
- creates one direct StringMap entry by default
- creates an additional redirect entry when `Redirect to` is filled in
- excludes `VS_CL1009*` LB vServers from the direct LB vServer dropdown

Argument-driven examples:

```powershell
.\Create-SMEntries.ps1 `
   -Url 'printer.millaard.nl' `
   -Scope ANY `
   -LBvServer 'VS_printer.millaard.nl_P'

.\Create-SMEntries.ps1 `
   -Url 'https://webmail.millaard.nl/owa' `
   -Scope ANY `
   -LBvServer 'VS_webmail.millaard.nl_P' `
   -ResponseCode 302 `
   -Destination '/owa'

.\Create-SMEntries.ps1 `
   -EntryKey 'cs_millaard.nl_ssl;any;printer.millaard.nl' `
   -EntryValue 'vs=VS_printer.millaard.nl_P;'
```

- `CoreLogicPrefix`: LB vServers with this prefix are excluded from export

### Import

```powershell
.\Import-LBvServers.ps1 `
   -NetScalerHost vpx01 `
   -NetScalerUser nsroot `
   -NetScalerPassword nsr00t
```

Parameters:

- `NetScalerHost`: Hostname or IP address of the Citrix ADC / NetScaler appliance
- `NetScalerUser`: Username for the Nitro API
- `NetScalerPassword`: Password for the Nitro API

## Requirements

- PowerShell 5.1 or higher
- Access to the Citrix ADC / NetScaler Nitro API
- `Out-GridView` availability for selection during import

## Typical Workflow

1. Run the export script against the source NetScaler.
2. Review the generated JSON files in the export folder.
3. Keep that folder next to `Import-LBvServers.ps1`.
4. Run the import script against the target NetScaler.
5. Select the vServers to import in `Out-GridView`.

## Disclaimer

Use these scripts at your own risk. Always test in a non-production environment before applying changes to production.
