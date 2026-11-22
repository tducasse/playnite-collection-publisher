# Builds a library snapshot JSON from a Playnite LiteDB backup, using the same
# field names/shape as CollectionPublisher.psm1's Get-LibrarySnapshot.
param(
    # Point this at the "library" folder of an unzipped Playnite backup.
    [string]$LibraryDir = "$env:TEMP\playnite-backup\library",
    [string]$OutFile = "$env:TEMP\collection-publisher\snapshot.json"
)

$ErrorActionPreference = 'Stop'
Add-Type -Path "$env:LOCALAPPDATA\Playnite\LiteDB.dll"

function Read-Coll {
    param([string]$File, [string]$Name)
    if (-not (Test-Path (Join-Path $LibraryDir $File))) { return @() }
    $db = New-Object LiteDB.LiteDatabase("Filename=$(Join-Path $LibraryDir $File);ReadOnly=true")
    $rows = @($db.GetCollection($Name).FindAll())
    $db.Dispose()
    return $rows
}

function Map-Names {
    param($Rows)
    $map = @{}
    foreach ($r in $Rows) { $map[$r['_id'].AsString] = $r['Name'].AsString }
    return $map
}

$games = Read-Coll 'games.db' 'Game'
$sources = Map-Names (Read-Coll 'sources.db' 'GameSource')
$genres = Map-Names (Read-Coll 'genres.db' 'Genre')
$features = Map-Names (Read-Coll 'features.db' 'GameFeature')
$tags = Map-Names (Read-Coll 'tags.db' 'Tag')
$platforms = Map-Names (Read-Coll 'platforms.db' 'Platform')
$companies = Map-Names (Read-Coll 'companies.db' 'Company')
$series = Map-Names (Read-Coll 'series.db' 'Series')
$completion = Map-Names (Read-Coll 'completionstatuses.db' 'CompletionStatus')

$access = @{
    'Steam'='owned'; 'Epic'='owned'; 'GOG'='owned'; 'Battle.net'='owned'; 'itch.io'='owned'; 'Humble'='owned';
    'Riot Games'='owned'; 'Steam Family Sharing'='shared'; 'Xbox Game Pass'='gamepass';
    'Xbox'='unknown'; 'EA app'='eaplay'; 'Ubisoft Connect'='ubisoftplus'
}

function Has($doc, $key) {
    $v = $doc[$key]
    return ($null -ne $v -and -not $v.IsNull)
}

function Names($value, $map) {
    if ($null -eq $value -or $value.IsNull) { return @() }
    $out = @()
    foreach ($v in $value.AsArray) {
        $key = $v.AsString
        if ($map.ContainsKey($key)) { $out += $map[$key] }
    }
    return $out
}

$rows = foreach ($g in $games) {
    $sid = if (Has $g 'SourceId') { $g['SourceId'].AsString } else { $null }
    $store = if ($sid -and $sources.ContainsKey($sid)) { $sources[$sid] } else { $null }

    $release = $null; $year = $null
    if (Has $g 'ReleaseDate') {
        $rd = $g['ReleaseDate'].AsDocument
        if ($rd -and $rd['Year'] -and $rd['Year'].AsInt32 -gt 0) {
            $year = $rd['Year'].AsInt32
            $month = if ($rd['Month'].AsInt32 -gt 0) { $rd['Month'].AsInt32 } else { 1 }
            $day = if ($rd['Day'].AsInt32 -gt 0) { $rd['Day'].AsInt32 } else { 1 }
            $release = '{0:D4}-{1:D2}-{2:D2}' -f $year, $month, $day
        }
    }

    $csid = if (Has $g 'CompletionStatusId') { $g['CompletionStatusId'].AsString } else { $null }

    [pscustomobject]@{
        id             = $g['_id'].AsString
        name           = $g['Name'].AsString
        sortName       = $(if (Has $g 'SortingName') { $g['SortingName'].AsString } else { $g['Name'].AsString })
        store          = $store
        access         = $(if ($store -and $access.ContainsKey($store)) { $access[$store] } else { 'unknown' })
        gameId         = $(if (Has $g 'GameId') { $g['GameId'].AsString } else { $null })
        platforms      = @(Names $g['PlatformIds'] $platforms)
        genres         = @(Names $g['GenreIds'] $genres)
        features       = @(Names $g['FeatureIds'] $features)
        tags           = @(Names $g['TagIds'] $tags)
        developers     = @(Names $g['DeveloperIds'] $companies)
        publishers     = @(Names $g['PublisherIds'] $companies)
        series         = $(if ((Has $g 'SeriesIds') -and $g['SeriesIds'].AsArray.Count -gt 0) { $series[$g['SeriesIds'].AsArray[0].AsString] } else { $null })
        releaseDate    = $release
        year           = $year
        added          = $(if (Has $g 'Added') { $g['Added'].AsDateTime.ToString('o') } else { $null })
        completion     = $(if ($csid -and $completion.ContainsKey($csid)) { $completion[$csid] } else { $null })
        userScore      = $(if (Has $g 'UserScore') { $g['UserScore'].AsInt32 } else { $null })
        communityScore = $(if (Has $g 'CommunityScore') { $g['CommunityScore'].AsInt32 } else { $null })
        criticScore    = $(if (Has $g 'CriticScore') { $g['CriticScore'].AsInt32 } else { $null })
        installed      = $g['IsInstalled'].AsBoolean
        favorite       = $g['Favorite'].AsBoolean
        hidden         = $g['Hidden'].AsBoolean
        sizeMb         = $(if (Has $g 'InstallSize') { [int][Math]::Round($g['InstallSize'].AsInt64 / 1MB) } else { $null })
        links          = $(if ((Has $g 'Links') -and $g['Links'].AsArray.Count -gt 0) {
                             @($g['Links'].AsArray | Where-Object {
                                 @('steam','itch','gog','epic games store','epic','ubisoft store','uplay','ubisoft connect','xbox','ea app','origin','battle.net','official website','website') -contains $_.AsDocument['Name'].AsString.ToLowerInvariant()
                             } | ForEach-Object {
                                 [pscustomobject]@{ name = $_.AsDocument['Name'].AsString; url = $_.AsDocument['Url'].AsString }
                             })
                         } else { @() })
    }
}

New-Item -ItemType Directory -Path (Split-Path $OutFile) -Force | Out-Null
ConvertTo-Json -InputObject @($rows) -Depth 6 -Compress | Set-Content -LiteralPath $OutFile -Encoding UTF8
"snapshot: $($rows.Count) games -> $OutFile"
