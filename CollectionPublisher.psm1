# Collection publisher - Playnite library -> static site with GeForce NOW availability
#
# Compares your Playnite library (and the current PC Game Pass catalogue)
# against NVIDIA's live GeForce NOW catalogue, and tags every game with
# "GFN ✓" (streamable from the store you own it on) or "GFN ✗" (not streamable).
# Also writes an HTML report.
#
# Script extension for Playnite 10/11. PowerShell 5.1 only (Playnite's runtime).

# Folder this module lives in (used to find GFNWorker.ps1).
$script:ModuleRoot = $PSScriptRoot

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

$script:Config = @{
    # GeForce NOW catalogue region. Change Country/Language to match your GFN region.
    Country       = 'GB'
    Language      = 'en_GB'

    # Microsoft Store region used for the Game Pass catalogue.
    Market        = 'GB'
    MarketLanguage = 'en-gb'

    GfnEndpoint   = 'https://api-prod.nvidia.com/services/gfngames/v1/gameList'
    GpListId      = '609d944c-d395-4c0a-9ea4-e9f39b52c1ad'   # PC Game Pass, all games
    EaListId      = '1d33fbb9-b895-4732-a8ca-a55c8b99fa2c'   # EA Play (included in PC Game Pass)

    CacheHours    = 24          # re-download the catalogues at most once a day
    MaxPages      = 40

    FeatureOn     = 'GFN ✓'
    FeatureOff    = 'GFN ✗'

    # Playnite source name -> GeForce NOW store code
    Stores        = @{
        'Steam'                = 'STEAM'
        'Steam Family Sharing' = 'STEAM'
        'Epic'                 = 'EPIC'
        'GOG'                  = 'GOG'
        'Ubisoft Connect'      = 'UPLAY'
        'EA app'               = 'EA_APP'
        'Origin'               = 'EA_APP'
        'Battle.net'           = 'BATTLENET'
        'Xbox'                 = 'XBOX'
        'Xbox Game Pass'       = 'XBOX'
    }

    # Sources whose games can run through more than one launcher.
    # (Game Pass EA Play titles run through the EA app, Ubisoft titles through
    # Ubisoft Connect, Blizzard titles through Battle.net.)
    MultiLauncher  = @('Xbox', 'Xbox Game Pass')
    Launchers      = @('XBOX', 'EA_APP', 'UPLAY', 'BATTLENET')

    # Per-store behaviour in GeForce NOW's "Game store accounts" screen:
    #   auto       - library synced by NVIDIA
    #   mark       - "Game library sync - Not supported" (Epic) -> Mark as owned
    # Stores not listed are auto. EA Play is handled separately (the licence has
    # to exist in the EA app first).
    SyncByStore   = @{ 'Epic' = 'mark' }

    # Only keep links we might show (store page / official site), not Twitch/Twitter.
    LinkNames     = @('steam', 'itch', 'gog', 'epic games store', 'epic', 'ubisoft store',
                      'uplay', 'ubisoft connect', 'xbox', 'ea app', 'origin', 'battle.net',
                      'official website', 'website')
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-GfnLog {
    param([string]$Message)
    $log = Join-Path (Get-GfnDataDir) 'gfncheck.log'
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    try { Add-Content -LiteralPath $log -Value $line -Encoding UTF8 } catch { }
    Write-Verbose $Message
}

function Get-GfnDataDir {
    # Playnite passes $CurrentExtensionDataPath to script extensions.
    $root = $script:DataDirOverride
    if (-not $root) { $root = $CurrentExtensionDataPath }
    if (-not $root) { $root = Join-Path $PlayniteApi.Paths.ExtensionsDataPath 'CollectionPublisher' }
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    return $root
}

function Get-CachedJson {
    param([string]$Path, [int]$MaxAgeHours)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $age = (Get-Date) - (Get-Item -LiteralPath $Path).LastWriteTime
    if ($age.TotalHours -gt $MaxAgeHours) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-GfnLog "Cache read failed for $Path : $($_.Exception.Message)"
        return $null
    }
}

function Save-Json {
    param($Object, [string]$Path)
    $json = ConvertTo-Json -InputObject $Object -Depth 10 -Compress
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
}

function Invoke-Utf8Request {
    <#
        PowerShell 5.1 decodes JSON as ISO-8859-1 when the server omits the
        charset, which turns every (R)/(TM) into two characters and breaks
        title matching. Read the raw bytes and decode UTF-8 instead.
    #>
    param(
        [string]$Uri,
        [string]$Method = 'GET',
        [string]$Body,
        [int]$TimeoutSec = 60
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = $Method
    $request.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    $request.Timeout = $TimeoutSec * 1000
    $request.ReadWriteTimeout = $TimeoutSec * 1000

    if ($Body) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $request.ContentType = 'application/json'
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Dispose()
    }

    try {
        $response = $request.GetResponse()
    } catch [System.Net.WebException] {
        $errorResponse = $_.Exception.Response
        if ($errorResponse) {
            $errorReader = New-Object System.IO.StreamReader($errorResponse.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $errorText = $errorReader.ReadToEnd()
            $errorReader.Dispose()
            throw ("HTTP {0} for {1}: {2}" -f [int]$errorResponse.StatusCode, $Uri, $errorText)
        }
        throw
    }

    $reader = $null
    try {
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
    } finally {
        if ($reader) { $reader.Dispose() }
        $response.Dispose()
    }

    return ($text | ConvertFrom-Json)
}

function Invoke-GraphQL {
    param([string]$Query, [int]$TimeoutSec = 60)
    return Invoke-Utf8Request -Uri $script:Config.GfnEndpoint -Method 'POST' -Body $Query -TimeoutSec $TimeoutSec
}

# ---------------------------------------------------------------------------
# Title normalisation
# ---------------------------------------------------------------------------

$script:RomanMap = @{
    'ii' = '2'; 'iii' = '3'; 'iv' = '4'; 'v' = '5'; 'vi' = '6'
    'vii' = '7'; 'viii' = '8'; 'ix' = '9'; 'xi' = '11'; 'xii' = '12'
}

# Words that never help identify a game (editions, platform noise, filler).
$script:NoiseWords = @(
    'the', 'standard', 'deluxe', 'ultimate', 'premium', 'definitive',
    'complete', 'enhanced', 'gold', 'legendary', 'digital', 'anniversary',
    'goty', 'game', 'of', 'year', 'special', 'collector', 'collectors',
    'remastered', 'remaster', 'edition', 'pc', 'windows', 'xbox', 'version',
    'preview', 'cross', 'gen', 'english', 'us'
)

function ConvertTo-GfnKey {
    <#
        Turns a store title into a comparable key:
          "The Elder Scrolls IV: Oblivion™ GOTY Edition (PC)"
            -> "elder scrolls 4 oblivion"
          "Assassin's Creed® II - Deluxe Edition"
            -> "assassins creed 2"
    #>
    param(
        [string]$Title,
        # Strict keeps edition/platform words, so "Control" and
        # "Control Ultimate Edition" stay different titles.
        [switch]$Strict
    )

    if ([string]::IsNullOrWhiteSpace($Title)) { return '' }

    $s = $Title

    # Trademark glyphs -> NFKD would turn them into "TM"/"R"; drop them first.
    $s = $s -replace '[\u2122\u00AE\u00A9\u2120]', ''

    # Fold accents: "Pokémon" -> "Pokemon".
    $s = $s.Normalize([System.Text.NormalizationForm]::FormKD)
    $s = $s -replace '[\u0300-\u036f]', ''

    $s = $s.ToLowerInvariant()

    # "(2020)" style disambiguators are noise.
    $s = $s -replace '\(\s*(19|20)\d\d\s*\)', ' '

    # "&" -> "and" so "Orcs Must Die & Chaos" == "Orcs Must Die and Chaos".
    $s = $s -replace '&', ' and '

    # Apostrophes vanish (Assassin's -> assassins), everything else separates.
    $s = $s -replace "['\u2018\u2019\u0060\u00B4]", ''
    $s = $s -replace '[^a-z0-9]+', ' '

    # "<year> Edition" is noise, but bare numbers are part of the title:
    # stripping them would turn "Cyberpunk 2077" into "cyberpunk".
    $s = $s -replace '\b(19|20)\d\d\s+edition\b', ' '

    $tokens = @()
    foreach ($word in ($s -split '\s+')) {
        if (-not $word) { continue }
        if (-not $Strict -and $script:NoiseWords -contains $word) { continue }
        if ($script:RomanMap.ContainsKey($word)) { $word = $script:RomanMap[$word] }
        $tokens += $word
    }

    return ($tokens -join ' ')
}

# ---------------------------------------------------------------------------
# GeForce NOW catalogue
# ---------------------------------------------------------------------------

function Get-GfnCatalog {
    param([switch]$ForceRefresh)

    $cache = Join-Path (Get-GfnDataDir) ("gfn-v2-{0}.json" -f $script:Config.Country)
    if (-not $ForceRefresh) {
        $cached = Get-CachedJson -Path $cache -MaxAgeHours $script:Config.CacheHours
        if ($cached) {
            Write-GfnLog "Using cached GFN catalogue ($($cached.Count) apps)"
            return $cached
        }
    }

    Write-GfnLog 'Downloading GeForce NOW catalogue...'
    $apps = New-Object System.Collections.Generic.List[object]
    $after = $null

    for ($page = 1; $page -le $script:Config.MaxPages; $page++) {
        $afterArg = if ($after) { 'after:"' + $after + '"' } else { '' }
        $query = @"
{ apps(country:"$($script:Config.Country)" language:"$($script:Config.Language)" orderBy:"itemMetadata.gfnPopularityRank:ASC" $afterArg) {
    numberReturned
    pageInfo { endCursor hasNextPage }
    items { title gfn { playType } variants { appStore } }
} }
"@
        $result = Invoke-GraphQL -Query $query
        if (-not $result -or -not $result.data -or -not $result.data.apps) {
            throw 'GeForce NOW catalogue request returned no data.'
        }

        foreach ($item in @($result.data.apps.items)) {
            if ($item) { $apps.Add($item) }
        }

        Write-GfnLog "GFN page $page : $($result.data.apps.numberReturned) apps (total $($apps.Count))"
        Write-GfnStatus "downloading the GeForce NOW catalogue (page $page, $($apps.Count) apps)..."

        if (-not $result.data.apps.pageInfo.hasNextPage) { break }
        $after = $result.data.apps.pageInfo.endCursor
        if (-not $after) { break }
    }

    # NB: PS 5.1's @() fails on List[object]; use ToArray().
    $apps = $apps.ToArray()
    Save-Json -Object $apps -Path $cache
    return $apps
}

# ---------------------------------------------------------------------------
# PC Game Pass catalogue
# ---------------------------------------------------------------------------

function Get-XboxCatalogList {
    param([string]$ListId)

    $url = "https://catalog.gamepass.com/sigls/v2?id=$ListId&language=$($script:Config.MarketLanguage)&market=$($script:Config.Market)"
    $raw = Invoke-Utf8Request -Uri $url
    return @($raw | Where-Object { $_.id } | ForEach-Object { $_.id })
}

function Get-XboxProducts {
    param([string[]]$Ids)

    $products = New-Object System.Collections.Generic.List[object]
    $chunkSize = 100

    for ($i = 0; $i -lt $Ids.Count; $i += $chunkSize) {
        $chunk = $Ids[$i..([Math]::Min($i + $chunkSize - 1, $Ids.Count - 1))]
        $url = 'https://displaycatalog.mp.microsoft.com/v7.0/products?bigIds=' +
               ($chunk -join ',') +
               "&market=$($script:Config.Market)&languages=$($script:Config.MarketLanguage)&MS-CV=DGU1mcuYo0WMMp%2BF.1"
        $result = Invoke-Utf8Request -Uri $url

        foreach ($p in @($result.Products)) {
            if (-not $p) { continue }
            $loc = @($p.LocalizedProperties)[0]
            $products.Add([pscustomobject]@{
                Id        = $p.ProductId
                Title     = $loc.ProductTitle
                Publisher = $loc.PublisherName
                Type      = $p.ProductType
            })
        }
    }

    return $products.ToArray()
}

function Get-GamePassCatalog {
    param([switch]$ForceRefresh)

    $cache = Join-Path (Get-GfnDataDir) 'gamepass-v2.json'
    if (-not $ForceRefresh) {
        $cached = Get-CachedJson -Path $cache -MaxAgeHours $script:Config.CacheHours
        if ($cached) {
            Write-GfnLog "Using cached Game Pass catalogue ($($cached.Count) titles)"
            return $cached
        }
    }

    Write-GfnLog 'Downloading PC Game Pass catalogue...'
    $pcIds = Get-XboxCatalogList -ListId $script:Config.GpListId
    $eaIds = @()
    try { $eaIds = Get-XboxCatalogList -ListId $script:Config.EaListId } catch { Write-GfnLog "EA Play list failed: $($_.Exception.Message)" }

    $products = @(Get-XboxProducts -Ids $pcIds)
    $eaTitles = @{}
    if ($eaIds.Count -gt 0) {
        foreach ($p in @(Get-XboxProducts -Ids $eaIds)) { $eaTitles[$p.Title] = $true }
    }

    foreach ($p in $products) {
        $p | Add-Member -NotePropertyName 'IsEaPlay' -NotePropertyValue $eaTitles.ContainsKey($p.Title) -Force
    }

    Save-Json -Object $products -Path $cache
    return $products
}

# ---------------------------------------------------------------------------
# Matching
# ---------------------------------------------------------------------------

function Build-GfnIndex {
    param($Apps)

    $index = @{}
    foreach ($app in $Apps) {
        $title = [string]$app.title
        if (-not $title) { continue }
        $lower = $title.ToLowerInvariant()
        if ($lower -match 'demo|playtest|free trial') { continue }

        $key = ConvertTo-GfnKey -Title $title
        if (-not $key) { continue }

        $stores = @()
        foreach ($v in @($app.variants)) { if ($v -and $v.appStore) { $stores += [string]$v.appStore } }

        if (-not $index.ContainsKey($key)) {
            $index[$key] = New-Object System.Collections.Generic.List[object]
        }
        $index[$key].Add([pscustomobject]@{
            Title  = $title
            Stores = @($stores | Select-Object -Unique)
            PlayType = if ($app.gfn) { [string]$app.gfn.playType } else { '' }
        })
    }
    return $index
}

function Get-GfnOverrides {
    <#
        Optional corrections, read from overrides.json in the extension data folder:
            { "Mafia": "", "My Weird Title": "Actual GFN Title" }
        An empty value forces "not on GFN"; a value forces a lookup under that title.
    #>
    $path = Join-Path (Get-GfnDataDir) 'overrides.json'
    $map = @{}

    if (-not (Test-Path -LiteralPath $path)) {
        [System.IO.File]::WriteAllText($path, '{}', [System.Text.Encoding]::UTF8)
        return $map
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($raw) {
            foreach ($prop in $raw.PSObject.Properties) { $map[$prop.Name] = [string]$prop.Value }
        }
    } catch {
        Write-GfnLog "overrides.json is not valid JSON: $($_.Exception.Message)"
    }
    return $map
}

function Resolve-GfnMatch {
    param(
        [string]$Title,
        [string[]]$CandidateStores,
        [hashtable]$Index
    )

    $key = ConvertTo-GfnKey -Title $Title
    if (-not $key) { return $null }

    if (-not $Index.ContainsKey($key)) { return $null }

    $entries = $Index[$key]
    $allStores = @()
    foreach ($e in $entries) { $allStores += $e.Stores }
    $allStores = [string[]]@($allStores | Select-Object -Unique)

    $hit = @($allStores | Where-Object { $CandidateStores -contains $_ })

    $strictKey = ConvertTo-GfnKey -Title $Title -Strict
    $kind = 'edition'
    foreach ($e in $entries) {
        if ((ConvertTo-GfnKey -Title $e.Title -Strict) -eq $strictKey) { $kind = 'exact'; break }
    }

    return [pscustomobject]@{
        GfnTitle   = $entries[0].Title
        GfnStores  = $allStores
        Matched    = ($hit.Count -gt 0)
        MatchedVia = [string[]]@($hit)
        MatchKind  = $kind
        PlayType   = $entries[0].PlayType
    }
}

# ---------------------------------------------------------------------------
# Playnite feature handling
# ---------------------------------------------------------------------------

function Get-OrCreateFeature {
    param([string]$Name)

    $existing = @($PlayniteApi.Database.Features | Where-Object { $_.Name -eq $Name })
    if ($existing.Count -gt 0) { return $existing[0] }
    return $PlayniteApi.Database.Features.Add($Name)
}

function Set-GameFeature {
    param($Game, $Feature, [bool]$Enabled)

    $ids = New-Object 'System.Collections.Generic.List[System.Guid]'
    foreach ($id in $Game.FeatureIds) { $ids.Add($id) }

    $has = $ids.Contains($Feature.Id)
    if ($Enabled -and -not $has) {
        $ids.Add($Feature.Id)
    } elseif (-not $Enabled -and $has) {
        $ids.Remove($Feature.Id) | Out-Null
    } else {
        return $false
    }

    $Game.FeatureIds = $ids
    $PlayniteApi.Database.Games.Update($Game)
    return $true
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

# The heavy lifting runs in a separate PowerShell process (PublishWorker.ps1) so
# the Playnite UI never blocks. This half of the module only reads the database,
# writes settings and talks to the UI; the worker does HTTP, JSON and git.

function Set-GfnDataDir {
    param([string]$Path)
    $script:DataDirOverride = $Path
}

function Get-GfnStatusPath   { Join-Path (Get-GfnDataDir) 'status.json' }
function Get-GfnResultPath   { Join-Path (Get-GfnDataDir) 'result.json' }
function Get-GfnErrorPath    { Join-Path (Get-GfnDataDir) 'error.json' }
function Get-GfnLockPath     { Join-Path (Get-GfnDataDir) 'running.lock' }
function Get-GfnJobPath      { Join-Path (Get-GfnDataDir) 'job.json' }
function Get-GfnSnapshotPath { Join-Path (Get-GfnDataDir) 'snapshot.json' }
function Get-GfnSettingsPath { Join-Path (Get-GfnDataDir) 'settings.json' }

function Write-GfnStatus {
    param([string]$Text)
    Write-GfnLog "status: $Text"
    if ($script:NotifyProgress) { Set-PublishNotification -Text ('Collection: ' + $Text) }
}

function Read-GfnJsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

function Get-PublishSettings {
    $path = Get-GfnSettingsPath
    $defaults = [pscustomobject]@{
        SitePath = ''
        SiteUrl  = ''
        Push     = $true
        CommitMessage = 'update library'
        # Per-store behaviour in GeForce NOW's "Game store accounts" screen.
        #   auto       - library synced by NVIDIA
        #   mark       - "Game library sync - Not supported" (Epic) -> Mark as owned
        #   claim+mark - licence lives in another app first (EA Play via Game Pass)
        # Anything not listed is treated as auto.
        SyncByStore = @{ 'Epic' = 'mark' }
        AccessBySource = @{
            'Steam'                = 'owned'
            'Epic'                 = 'owned'
            'GOG'                  = 'owned'
            'Battle.net'           = 'owned'
            'itch.io'              = 'owned'
            'Humble'               = 'owned'
            'Riot Games'           = 'owned'
            'Steam Family Sharing' = 'shared'
            'Xbox Game Pass'       = 'gamepass'
            'Xbox'                 = 'gamepass'
            # PC Game Pass entitles games that run in other launchers, so the
            # access is Game Pass even though the licence lives in EA/Ubisoft.
            'EA app'               = 'gamepass'
            'Ubisoft Connect'      = 'gamepass'
        }
    }

    if (-not (Test-Path -LiteralPath $path)) {
        ConvertTo-Json -InputObject $defaults -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
        return $defaults
    }

    $loaded = Read-GfnJsonFile -Path $path
    if (-not $loaded) { return $defaults }

    $settings = [pscustomobject]@{}
    foreach ($prop in $defaults.PSObject.Properties) {
        $value = $loaded.($prop.Name)
        if ($null -eq $value) { $value = $prop.Value }
        $settings | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $value
    }

    # JSON gives back a PSCustomObject; the rest of the code expects a hashtable.
    $accessTable = @{}
    if ($settings.AccessBySource) {
        foreach ($entry in $settings.AccessBySource.PSObject.Properties) {
            $accessTable[$entry.Name] = [string]$entry.Value
        }
    }
    $settings.AccessBySource = $accessTable

    $syncTable = @{}
    if ($settings.SyncByStore) {
        foreach ($entry in $settings.SyncByStore.PSObject.Properties) {
            $syncTable[$entry.Name] = [string]$entry.Value
        }
    }
    $settings.SyncByStore = $syncTable

    return $settings
}

function Save-PublishSettings {
    param($Settings)
    ConvertTo-Json -InputObject $Settings -Depth 5 | Set-Content -LiteralPath (Get-GfnSettingsPath) -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Library snapshot (main thread, Playnite API only)
# ---------------------------------------------------------------------------

function Get-NameMap {
    param($Collection)
    $map = @{}
    if ($Collection) {
        foreach ($item in $Collection) {
            if ($null -ne $item.Id) { $map[$item.Id] = $item.Name }
        }
    }
    return $map
}

function ConvertTo-NameList {
    param($Ids, $Map)
    $out = @()
    foreach ($id in $Ids) {
        if ($Map.ContainsKey($id)) { $out += $Map[$id] }
    }
    return $out
}

function Get-LibrarySnapshot {
    param($AccessBySource)

    $genres     = Get-NameMap $PlayniteApi.Database.Genres
    $features   = Get-NameMap $PlayniteApi.Database.Features
    $tags       = Get-NameMap $PlayniteApi.Database.Tags
    $platforms  = Get-NameMap $PlayniteApi.Database.Platforms
    $developers = Get-NameMap $PlayniteApi.Database.Companies
    $series     = Get-NameMap $PlayniteApi.Database.Series
    $sources    = Get-NameMap $PlayniteApi.Database.Sources
    $completion = Get-NameMap $PlayniteApi.Database.CompletionStatuses

    $rows = foreach ($game in $PlayniteApi.Database.Games) {
        $sourceName = $null
        if ($game.SourceId -and $game.SourceId -ne [Guid]::Empty -and $sources.ContainsKey($game.SourceId)) {
            $sourceName = $sources[$game.SourceId]
        }

        $access = 'unknown'
        if ($sourceName -and $AccessBySource -and $AccessBySource.ContainsKey($sourceName)) {
            $access = $AccessBySource[$sourceName]
        }

        $releaseDate = $null
        $year = $null
        if ($game.ReleaseDate) {
            $year = $game.ReleaseDate.Year
            if ($year) {
                $month = if ($game.ReleaseDate.Month) { $game.ReleaseDate.Month } else { 1 }
                $day   = if ($game.ReleaseDate.Day) { $game.ReleaseDate.Day } else { 1 }
                $releaseDate = ('{0:D4}-{1:D2}-{2:D2}' -f $year, $month, $day)
            }
        }

        [pscustomobject]@{
            id             = [string]$game.Id
            name           = $game.Name
            sortName       = if ($game.SortingName) { $game.SortingName } else { $game.Name }
            store          = $sourceName
            access         = $access
            gameId         = $game.GameId
            platforms      = @(ConvertTo-NameList $game.PlatformIds $platforms)
            genres         = @(ConvertTo-NameList $game.GenreIds $genres)
            features       = @(ConvertTo-NameList $game.FeatureIds $features)
            tags           = @(ConvertTo-NameList $game.TagIds $tags)
            developers     = @(ConvertTo-NameList $game.DeveloperIds $developers)
            publishers     = @(ConvertTo-NameList $game.PublisherIds $developers)
            series         = if ($game.SeriesIds -and @($game.SeriesIds).Count -gt 0) { ($series[$game.SeriesIds[0]]) } else { $null }
            releaseDate    = $releaseDate
            year           = $year
            playtime       = [int][Math]::Round($game.Playtime / 60)
            playCount      = [int]$game.PlayCount
            added          = if ($game.Added) { $game.Added.ToString('o') } else { $null }
            lastPlayed     = if ($game.LastActivity) { $game.LastActivity.ToString('o') } else { $null }
            completion     = if ($game.CompletionStatusId -and $completion.ContainsKey($game.CompletionStatusId)) { $completion[$game.CompletionStatusId] } else { $null }
            userScore      = $game.UserScore
            communityScore = $game.CommunityScore
            criticScore    = $game.CriticScore
            installed      = [bool]$game.IsInstalled
            favorite       = [bool]$game.Favorite
            hidden         = [bool]$game.Hidden
            sizeMb         = if ($game.InstallSize) { [int][Math]::Round($game.InstallSize / 1MB) } else { $null }
            links          = @($game.Links | Where-Object {
                                 $_ -and $_.Url -and ($script:Config.LinkNames -contains ([string]$_.Name).ToLowerInvariant())
                             } | ForEach-Object {
                                 [pscustomobject]@{ name = $_.Name; url = $_.Url }
                             })
        }
    }

    return @($rows)
}

# ---------------------------------------------------------------------------
# Core: GeForce NOW matching (no Playnite API - runs in the worker)
# ---------------------------------------------------------------------------

function Invoke-GfnCheckCore {
    param(
        [object[]]$GameList,
        [switch]$ForceRefresh
    )

    $started = Get-Date
    Write-GfnStatus 'Downloading the GeForce NOW catalogue...'
    $gfnApps = @(Get-GfnCatalog -ForceRefresh:$ForceRefresh)
    $index   = Build-GfnIndex -Apps $gfnApps
    Write-GfnLog "Indexed $($index.Count) distinct GFN titles from $($gfnApps.Count) apps"

    Write-GfnStatus "Matching $($GameList.Count) library games..."
    $overrides = Get-GfnOverrides
    $stats = @{ streamable = 0; notStreamable = 0; wrongStore = 0; gamePassTotal = 0; gamePassNotOnGfn = 0 }

    foreach ($game in $GameList) {
        $storeCode = $null
        if ($game.store -and $script:Config.Stores.ContainsKey([string]$game.store)) {
            $storeCode = $script:Config.Stores[[string]$game.store]
        }

        if (-not $storeCode) {
            $game | Add-Member -NotePropertyName gfn -NotePropertyValue 'na' -Force
            $game | Add-Member -NotePropertyName gfnTitle -NotePropertyValue $null -Force
            $game | Add-Member -NotePropertyName gfnStores -NotePropertyValue @() -Force
            $game | Add-Member -NotePropertyName match -NotePropertyValue $null -Force
            continue
        }

        $candidates = @($storeCode)
        if ($script:Config.MultiLauncher -contains [string]$game.store) { $candidates = $script:Config.Launchers }

        $lookupTitle = [string]$game.name
        $forceNoMatch = $false
        if ($overrides.ContainsKey([string]$game.name)) {
            $overrideTitle = $overrides[[string]$game.name]
            if ([string]::IsNullOrWhiteSpace($overrideTitle)) { $forceNoMatch = $true }
            else { $lookupTitle = $overrideTitle }
        }

        $match = $null
        if (-not $forceNoMatch) {
            $match = Resolve-GfnMatch -Title $lookupTitle -CandidateStores $candidates -Index $index
        }

        $status = 'no'
        if ($match) { $status = if ($match.Matched) { 'yes' } else { 'other' } }

        switch ($status) {
            'yes'   { $stats.streamable++ }
            'other' { $stats.wrongStore++; $stats.notStreamable++ }
            default { $stats.notStreamable++ }
        }

        # GeForce NOW does not detect every licence by itself:
        #   EA  - the game has to be in your EA account (claim it in the EA app)
        #   Epic - GFN does not sync Epic automatically, you mark the game as owned
        # Steam/Xbox/Ubisoft/Battle.net are detected automatically.
        # NVIDIA docs: "select MARK AS OWNED on the game in GeForce NOW". Only the
        # Steam library is synced automatically; every other store needs that one
        # click, and EA Play (Game Pass) needs the EA app licence before it.
        $sync = $null
        $syncVia = $null
        if ($status -eq 'yes' -and $match) {
            $via = @($match.MatchedVia)
            $sync = 'auto'
            if ($game.store -and $script:Config.SyncByStore.ContainsKey([string]$game.store)) {
                $sync = $script:Config.SyncByStore[[string]$game.store]
                if ($sync -eq 'mark') { $syncVia = 'GeForce NOW' }
            }
            # A Game Pass EA Play game has no licence in your EA account yet.
            if (($via -contains 'EA_APP') -and -not ($via -contains $storeCode)) {
                $sync = 'claim+mark'; $syncVia = 'EA app'
            }
        }

        $game | Add-Member -NotePropertyName gfn -NotePropertyValue $status -Force
        $game | Add-Member -NotePropertyName gfnTitle -NotePropertyValue $(if ($match) { $match.GfnTitle } else { $null }) -Force
        $game | Add-Member -NotePropertyName gfnStores -NotePropertyValue $(if ($match) { $match.GfnStores } else { @() }) -Force
        $game | Add-Member -NotePropertyName match -NotePropertyValue $(if ($match) { $match.MatchKind } else { $null }) -Force
        $game | Add-Member -NotePropertyName sync -NotePropertyValue $sync -Force
        $game | Add-Member -NotePropertyName syncVia -NotePropertyValue $syncVia -Force
    }

    $gpRows = New-Object System.Collections.Generic.List[object]
    $gpTotal = 0
    try {
        Write-GfnStatus 'Downloading the PC Game Pass catalogue...'
        $gpCatalog = @(Get-GamePassCatalog -ForceRefresh:$ForceRefresh)
        $gpTotal = $gpCatalog.Count
        Write-GfnStatus "Matching $gpTotal Game Pass titles..."

        foreach ($p in $gpCatalog) {
            $match = Resolve-GfnMatch -Title $p.Title -CandidateStores $script:Config.Launchers -Index $index
            $status = 'no'
            if ($match) { $status = if ($match.Matched) { 'yes' } else { 'other' } }
            if ($status -ne 'yes') { $stats.gamePassNotOnGfn++ }

            # Game Pass titles play through the Xbox app, so an EA-only match means
            # the game is not in the EA account yet.
            $gpVia = if ($match) { @($match.MatchedVia) } else { @() }
            $gpSync = $null
            $gpSyncVia = $null
            if ($status -eq 'yes') {
                $gpSync = 'auto'
                if (($gpVia -contains 'EA_APP') -and -not ($gpVia -contains 'XBOX')) {
                    $gpSync = 'claim+mark'; $gpSyncVia = 'EA app'
                }
            }

            $gpRows.Add([pscustomobject]@{
                name       = $p.Title
                publisher  = $p.Publisher
                gfn        = $status
                gfnTitle   = if ($match) { $match.GfnTitle } else { $null }
                gfnStores  = if ($match) { $match.GfnStores } else { @() }
                match      = if ($match) { $match.MatchKind } else { $null }
                sync       = $gpSync
                syncVia    = $gpSyncVia
            })
        }
    } catch {
        Write-GfnLog "Game Pass catalogue failed: $($_.Exception.Message)"
    }

    $stats.gamePassTotal = $gpTotal

    Write-GfnLog ("Check finished in {0:n1}s" -f ((Get-Date) - $started).TotalSeconds)

    return [pscustomobject]@{
        stats    = $stats
        games    = @($GameList)
        gamePass = $gpRows.ToArray()
        catalog  = [pscustomobject]@{
            country   = $script:Config.Country
            fetchedAt = (Get-Date).ToString('o')
            titles    = @($gfnApps).Count
        }
    }
}

# ---------------------------------------------------------------------------
# Publishing (runs in the worker: JSON + site files + git)
# ---------------------------------------------------------------------------

function Copy-SiteTemplates {
    param([string]$SitePath)

    $templateRoot = Join-Path $script:ModuleRoot 'site'
    if (-not (Test-Path -LiteralPath $templateRoot)) {
        Write-GfnLog "No site templates at $templateRoot"
        return @()
    }

    $copied = @()
    foreach ($file in @('index.html', 'app.js', 'styles.css')) {
        $source = Join-Path $templateRoot $file
        $target = Join-Path $SitePath $file
        if ((Test-Path -LiteralPath $source) -and -not (Test-Path -LiteralPath $target)) {
            Copy-Item -LiteralPath $source -Destination $target -Force
            $copied += $file
        }
    }
    return $copied
}

function Invoke-Git {
    param([string]$RepoPath, [string[]]$Arguments)

    $git = (Get-Command git -ErrorAction SilentlyContinue).Source
    if (-not $git) { throw 'git.exe was not found in PATH.' }

    # git writes progress/warnings to stderr; with ErrorActionPreference=Stop
    # PowerShell would turn those into terminating errors. Capture as text.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $git -C $RepoPath @Arguments 2>&1 | ForEach-Object { "$_" } | Out-String
    } finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output.Trim() }
}

function Publish-SiteData {
    param(
        $Result,
        [string]$SitePath,
        [switch]$Push,
        [string]$CommitMessage = 'update library'
    )

    if (-not $SitePath) { throw 'SitePath is not configured.' }
    if (-not (Test-Path -LiteralPath $SitePath)) {
        New-Item -ItemType Directory -Path $SitePath -Force | Out-Null
    }

    $copied = @(Copy-SiteTemplates -SitePath $SitePath)
    if ($copied.Count -gt 0) { Write-GfnLog ("Initialised site files: " + ($copied -join ', ')) }

    $dataDir = Join-Path $SitePath 'data'
    if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }

    Write-GfnStatus 'Writing data/games.json...'
    $payload = [pscustomobject]@{
        generatedAt = (Get-Date).ToString('o')
        catalog     = $Result.catalog
        stats       = $Result.stats
        games       = $Result.games
        gamePass    = $Result.gamePass
    }
    $json = ConvertTo-Json -InputObject $payload -Depth 8 -Compress
    $target = Join-Path $dataDir 'games.json'
    [System.IO.File]::WriteAllText($target, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-GfnLog ("Wrote {0} ({1:n0} KB)" -f $target, ((Get-Item -LiteralPath $target).Length / 1KB))

    if (-not $Push) {
        return [pscustomobject]@{ pushed = $false; message = 'Push disabled'; filesCopied = $copied }
    }

    $isRepo = Test-Path -LiteralPath (Join-Path $SitePath '.git')
    if (-not $isRepo) {
        return [pscustomobject]@{ pushed = $false; message = 'Not a git repository (files written only)'; filesCopied = $copied }
    }

    Write-GfnStatus 'Committing and pushing...'
    $add = Invoke-Git -RepoPath $SitePath -Arguments @('add', '-A')
    if ($add.ExitCode -ne 0) { return [pscustomobject]@{ pushed = $false; message = "git add failed: $($add.Output)"; filesCopied = $copied } }

    $status = Invoke-Git -RepoPath $SitePath -Arguments @('status', '--porcelain')
    if (-not $status.Output) {
        return [pscustomobject]@{ pushed = $false; message = 'Nothing changed, nothing to push'; filesCopied = $copied }
    }

    $commit = Invoke-Git -RepoPath $SitePath -Arguments @('commit', '-m', $CommitMessage)
    if ($commit.ExitCode -ne 0) {
        return [pscustomobject]@{ pushed = $false; message = "git commit failed: $($commit.Output)"; filesCopied = $copied }
    }

    $pushResult = Invoke-Git -RepoPath $SitePath -Arguments @('push')
    if ($pushResult.ExitCode -ne 0) {
        return [pscustomobject]@{ pushed = $false; message = "git push failed: $($pushResult.Output)"; filesCopied = $copied }
    }

    return [pscustomobject]@{ pushed = $true; message = 'Pushed'; filesCopied = $copied }
}

# ---------------------------------------------------------------------------
# Applying results (main thread)
# ---------------------------------------------------------------------------

function Apply-GfnFeatures {
    param($Games)

    $featureOn  = Get-OrCreateFeature -Name $script:Config.FeatureOn
    $featureOff = Get-OrCreateFeature -Name $script:Config.FeatureOff
    $changed = 0

    $PlayniteApi.Database.Games.BeginBufferUpdate()
    try {
        foreach ($row in $Games) {
            $game = $PlayniteApi.Database.Games[[Guid]$row.id]
            if (-not $game) { continue }

            $isOn = ($row.gfn -eq 'yes')
            if (Set-GameFeature -Game $game -Feature $featureOn -Enabled $isOn) { $changed++ }
            if (Set-GameFeature -Game $game -Feature $featureOff -Enabled (-not $isOn)) { $changed++ }
        }
    } finally {
        $PlayniteApi.Database.Games.EndBufferUpdate()
    }

    Write-GfnLog "Applied features to $changed game/feature pairs"
}

# ---------------------------------------------------------------------------
# Synchronous run (tests / command line)
# ---------------------------------------------------------------------------

function Invoke-Publish {
    param(
        $Settings,
        [switch]$Apply,
        [switch]$ForceRefresh,
        [switch]$NoPush,
        [switch]$Quiet
    )

    if (-not $Settings) { $Settings = Get-PublishSettings }

    if ($Settings.SyncByStore) { $script:Config.SyncByStore = $Settings.SyncByStore }
    if ($Settings.AccessBySource) { $script:Config.AccessBySource = $Settings.AccessBySource }

    $script:NotifyProgress = -not $Quiet
    if (-not $Quiet) { Set-PublishNotification -Text 'Collection: reading the library...' }

    try {
        $snapshot = Get-LibrarySnapshot -AccessBySource $Settings.AccessBySource
        Write-GfnLog "Snapshot: $($snapshot.Count) games"

        $result = Invoke-GfnCheckCore -GameList $snapshot -ForceRefresh:$ForceRefresh

        if ($Apply) {
            Write-GfnStatus 'updating Playnite features...'
            Apply-GfnFeatures -Games $result.games
        }

        $publish = Publish-SiteData -Result $result -SitePath $Settings.SitePath `
            -Push:($Settings.Push -and -not $NoPush) -CommitMessage $Settings.CommitMessage

        if ($Quiet) {
            Set-PublishNotification -Text ("Collection: {0} games, {1} cloud-ready. {2}" -f `
                ($result.stats.streamable + $result.stats.notStreamable), $result.stats.streamable, $publish.message)
        } else {
            Show-PublishSummary -Stats $result.stats -Publish $publish -SiteUrl $Settings.SiteUrl
        }

        return [pscustomobject]@{
            stats    = $result.stats
            publish  = $publish
            games    = $result.games
            gamePass = $result.gamePass
        }
    } finally {
        $script:NotifyProgress = $false
    }
}

function Show-PublishSummary {
    param($Stats, $Publish, [string]$SiteUrl)

    $lines = @(
        "Games:            $($Stats.streamable + $Stats.notStreamable)",
        "Cloud-ready:      $($Stats.streamable)",
        "Laptop-only:      $($Stats.notStreamable)  (of which $($Stats.wrongStore) are on GFN for another store)",
        "Game Pass:        $($Stats.gamePassTotal) titles, $($Stats.gamePassNotOnGfn) not on GFN",
        '',
        "Publish:          $($Publish.message)"
    )
    if ($SiteUrl) {
        $lines += ''
        $lines += "Open $SiteUrl ?"
    }

    $answer = $PlayniteApi.Dialogs.ShowMessage(($lines -join [Environment]::NewLine), 'Collection published',
        [System.Windows.MessageBoxButton]::YesNo)
    if ($answer -eq [System.Windows.MessageBoxResult]::Yes -and $SiteUrl) {
        Start-Process $SiteUrl
    }
}

# ---------------------------------------------------------------------------
# Background runspace: publish without blocking Playnite's UI
#
# Playnite runs script extensions with PSThreadOptions.UseCurrentThread, so a
# scriptblock invoked from a DispatcherTimer or a worker thread has no runspace
# and throws ("There is no Runspace available to run scripts in this thread").
# Instead we open our own runspace, hand it the Playnite API, and run there.
# ---------------------------------------------------------------------------

$script:PublishJob = $null
$script:NotificationId = 'CollectionPublisher.status'
$script:NotifyProgress = $false

function Set-PublishNotification {
    param([string]$Text, [switch]$Error)
    try {
        $PlayniteApi.Notifications.Remove($script:NotificationId)
        $type = if ($Error) { 'Error' } else { 'Info' }
        $PlayniteApi.Notifications.Add($script:NotificationId, $Text, $type)
    } catch {
        Write-GfnLog "Notification failed: $($_.Exception.Message)"
    }
}

function Test-PublishRunning {
    if (-not $script:PublishJob) { return $false }
    return -not $script:PublishJob.Handle.IsCompleted
}

function Start-Publish {
    param([switch]$ForceRefresh, [switch]$Quiet)

    if (Test-PublishRunning) {
        if (-not $Quiet) {
            $PlayniteApi.Dialogs.ShowMessage('A publish is already running.', 'Collection publisher')
        }
        return
    }

    if ($script:PublishJob) {
        try { $script:PublishJob.PowerShell.Dispose() } catch { }
        try { $script:PublishJob.Runspace.Dispose() } catch { }
        $script:PublishJob = $null
    }

    $settings = Get-PublishSettings
    if (-not $settings.SitePath) {
        $picked = $PlayniteApi.Dialogs.SelectFolder()
        if (-not $picked) { return }
        $settings.SitePath = $picked
        Save-PublishSettings -Settings $settings
    }

    $modulePath = Join-Path $script:ModuleRoot 'CollectionPublisher.psm1'
    $dataDir = Get-GfnDataDir

    $initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initialState)
    $runspace.ApartmentState = 'MTA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('PlayniteApi', $PlayniteApi)

    $powerShell = [System.Management.Automation.PowerShell]::Create()
    $powerShell.Runspace = $runspace
    $null = $powerShell.AddScript(@'
param($modulePath, $dataDir, $settings, $force, $quiet)
Import-Module $modulePath -Force -WarningAction SilentlyContinue
Set-GfnDataDir -Path $dataDir
try {
    Invoke-Publish -Settings $settings -Apply -ForceRefresh:$force -Quiet:$quiet | Out-Null
} catch {
    Write-GfnLog ("Background publish failed: " + $_.Exception.ToString())
    Set-PublishNotification -Text ('Collection: publish failed - ' + $_.Exception.Message) -Error
}
'@).AddArgument($modulePath).AddArgument($dataDir).AddArgument($settings).
    AddArgument([bool]$ForceRefresh).AddArgument([bool]$Quiet)

    if (-not $Quiet) { Set-PublishNotification -Text 'Collection: starting...' }

    $handle = $powerShell.BeginInvoke()
    $script:PublishJob = [pscustomobject]@{
        PowerShell = $powerShell
        Handle     = $handle
        Runspace   = $runspace
    }

    Write-GfnLog "Started background publish in runspace $($runspace.InstanceId)"
}

function Stop-PublishJob {
    if (-not $script:PublishJob) { return }
    try { $script:PublishJob.PowerShell.Stop() } catch { }
    try { $script:PublishJob.PowerShell.Dispose() } catch { }
    try { $script:PublishJob.Runspace.Dispose() } catch { }
    $script:PublishJob = $null
}

# ---------------------------------------------------------------------------
# Playnite extension entry points
# ---------------------------------------------------------------------------

function GetMainMenuItems {
    param($getMainMenuItemsArgs)

    $publish = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $publish.Description = 'Publish collection'
    $publish.MenuSection = '@'
    $publish.FunctionName = 'Invoke-PublishFromMenu'

    $settings = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $settings.Description = 'Collection publisher settings'
    $settings.MenuSection = '@'
    $settings.FunctionName = 'Invoke-PublishSettingsFromMenu'

    return @($publish, $settings)
}

function Invoke-PublishFromMenu {
    param($scriptMainMenuItemActionArgs)
    Start-Publish -ForceRefresh
}

function Invoke-PublishSettingsFromMenu {
    param($scriptMainMenuItemActionArgs)

    $settings = Get-PublishSettings

    $folder = $PlayniteApi.Dialogs.SelectFolder($settings.SitePath)
    if (-not $folder) { return }
    $settings.SitePath = $folder

    $pushAnswer = $PlayniteApi.Dialogs.ShowMessage(
        "Push to git after publishing?`n`nRepository: $folder",
        'Collection publisher', [System.Windows.MessageBoxButton]::YesNo)
    $settings.Push = ($pushAnswer -eq [System.Windows.MessageBoxResult]::Yes)

    Save-PublishSettings -Settings $settings

    $PlayniteApi.Dialogs.ShowMessage(
        ("Site folder: {0}`nPush to git: {1}`nSite URL: {2}" -f $settings.SitePath, $settings.Push, $settings.SiteUrl),
        'Collection publisher settings saved')
}

function OnApplicationStopped {
    if ($script:PublishJob) { Stop-PublishJob }
}
