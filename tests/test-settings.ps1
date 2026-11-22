# Get-PublishSettings must return a hashtable for AccessBySource, whether the
# settings file was just created or loaded from JSON.
param([string]$ModulePath)

$ErrorActionPreference = 'Stop'
$dataDir = Join-Path $env:TEMP ('pubsettings-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

$global:PlayniteApi = [pscustomobject]@{
    Paths = [pscustomobject]@{ ExtensionsDataPath = $env:TEMP }
    Database = [pscustomobject]@{ Games = @(); Sources = @(); Genres = @(); Features = @(); Tags = @(); Platforms = @(); Companies = @(); Series = @(); CompletionStatuses = @() }
}

Import-Module $ModulePath -Force -WarningAction SilentlyContinue
$module = Get-Module CollectionPublisher
& $module { param($d) Set-GfnDataDir -Path $d } $dataDir

$first = & $module { Get-PublishSettings }
"created: AccessBySource type = $($first.AccessBySource.GetType().Name), entries = $($first.AccessBySource.Count)"
if ($first.AccessBySource -isnot [hashtable]) { throw 'fresh settings: not a hashtable' }

# second call reads the JSON file that was just written
$second = & $module { Get-PublishSettings }
"loaded:  AccessBySource type = $($second.AccessBySource.GetType().Name), entries = $($second.AccessBySource.Count)"
if ($second.AccessBySource -isnot [hashtable]) { throw 'loaded settings: not a hashtable' }
if ($second.AccessBySource['Xbox Game Pass'] -ne 'gamepass') { throw 'mapping lost' }
if ($second.AccessBySource['Steam'] -ne 'owned') { throw 'mapping lost' }

# and the snapshot accepts it
$snap = & $module { param($a) Get-LibrarySnapshot -AccessBySource $a } $second.AccessBySource
"snapshot with loaded settings: $($snap.Count) rows"
"OK"

Remove-Item $dataDir -Recurse -Force
