# Tests Get-LibrarySnapshot against a mock Playnite API (no Playnite needed).
param([string]$ModulePath)

$ErrorActionPreference = 'Stop'

function Coll { param($items) ,@($items) }

$gid = [Guid]::NewGuid(); $fid = [Guid]::NewGuid(); $tid = [Guid]::NewGuid()
$pid1 = [Guid]::NewGuid(); $co = [Guid]::NewGuid(); $se = [Guid]::NewGuid()
$src = [Guid]::NewGuid(); $cs = [Guid]::NewGuid()

$release = [pscustomobject]@{ Year = 2015; Month = 5; Day = 19 }

$game = [pscustomobject]@{
    Id = [Guid]::NewGuid(); Name = 'The Witcher 3: Wild Hunt'; SortingName = 'Witcher 3'
    SourceId = $src; GameId = '292030'
    PlatformIds = @($pid1); GenreIds = @($gid); FeatureIds = @($fid); TagIds = @($tid)
    DeveloperIds = @($co); PublisherIds = @($co); SeriesIds = @($se)
    ReleaseDate = $release; Playtime = [uint64](3600 * 48); PlayCount = [uint64]7
    Added = [datetime]'2020-01-02T03:04:05'; LastActivity = [datetime]'2026-11-01T10:00:00'
    CompletionStatusId = $cs; UserScore = 95; CommunityScore = 92; CriticScore = 93
    IsInstalled = $true; Favorite = $true; Hidden = $false; InstallSize = [uint64](50GB)
}

$hiddenGame = [pscustomobject]@{
    Id = [Guid]::NewGuid(); Name = 'Hidden Thing'; SortingName = $null
    SourceId = $src; GameId = $null
    PlatformIds = @($pid1); GenreIds = @(); FeatureIds = @(); TagIds = @()
    DeveloperIds = @(); PublisherIds = @(); SeriesIds = @()
    ReleaseDate = $null; Playtime = [uint64]0; PlayCount = [uint64]0
    Added = $null; LastActivity = $null; CompletionStatusId = $null
    UserScore = $null; CommunityScore = $null; CriticScore = $null
    IsInstalled = $false; Favorite = $false; Hidden = $true; InstallSize = $null
}

$global:PlayniteApi = [pscustomobject]@{
    Database = [pscustomobject]@{
        Games              = @($game, $hiddenGame)
        Genres             = Coll @([pscustomobject]@{ Id = $gid; Name = 'RPG' })
        Features           = Coll @([pscustomobject]@{ Id = $fid; Name = 'Single Player' })
        Tags               = Coll @([pscustomobject]@{ Id = $tid; Name = 'Open World' })
        Platforms          = Coll @([pscustomobject]@{ Id = $pid1; Name = 'PC (Windows)' })
        Companies          = Coll @([pscustomobject]@{ Id = $co; Name = 'CD Projekt RED' })
        Series             = Coll @([pscustomobject]@{ Id = $se; Name = 'The Witcher' })
        Sources            = Coll @([pscustomobject]@{ Id = $src; Name = 'Steam' })
        CompletionStatuses = Coll @([pscustomobject]@{ Id = $cs; Name = 'Beaten' })
    }
}

Import-Module $ModulePath -Force -WarningAction SilentlyContinue
$module = Get-Module CollectionPublisher
if (-not $module) { $module = Get-Module GFNCheck }

$access = @{ 'Steam' = 'owned'; 'Xbox' = 'unknown' }
$rows = & $module { param($a) Get-LibrarySnapshot -AccessBySource $a } $access

$failures = 0
function Check($name, $actual, $expected) {
    $ok = ($actual -eq $expected)
    if (-not $ok) { $script:failures++ }
    "{0}  {1}  (expected {2}, got {3})" -f ($(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $expected, $actual)
}

Check 'row count' $rows.Count 2
$w = $rows[0]
Check 'name' $w.name 'The Witcher 3: Wild Hunt'
Check 'sortName' $w.sortName 'Witcher 3'
Check 'store' $w.store 'Steam'
Check 'launcher' $w.launcher 'Steam'
Check 'access' $w.access 'owned'
Check 'genres' ($w.genres -join '|') 'RPG'
Check 'features' ($w.features -join '|') 'Single Player'
Check 'tags' ($w.tags -join '|') 'Open World'
Check 'series' $w.series 'The Witcher'
Check 'releaseDate' $w.releaseDate '2015-05-19'
Check 'year' $w.year 2015
Check 'completion' $w.completion 'Beaten'
Check 'installed' $w.installed $true
Check 'favorite' $w.favorite $true
Check 'sizeMb' $w.sizeMb 51200
Check 'added iso' ($w.added -like '2020-01-02T03:04:05*') $true
$h = $rows[1]
Check 'hidden game included' $h.hidden $true
Check 'hidden game null release' $h.releaseDate $null
Check 'hidden game empty arrays' ($h.genres.Count -eq 0) $true

"`n$($rows.Count) rows, $failures failure(s)"
if ($failures -gt 0) { exit 1 }
