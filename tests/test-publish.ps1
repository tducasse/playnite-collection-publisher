# End-to-end test of the publishing pipeline against a real Playnite backup:
# snapshot -> GFN matching -> games.json -> site files -> git commit + push.
param(
    [string]$Root = "$env:TEMP\collection-publisher-test",
    [switch]$ForceRefresh
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$site = Join-Path $Root 'site-repo'
$remote = Join-Path $Root 'remote.git'
$data = Join-Path $Root 'data'

New-Item -ItemType Directory -Path $data -Force | Out-Null
New-Item -ItemType Directory -Path $Root -Force | Out-Null

# work on a copy of the extension so the test never touches the repo
Copy-Item (Join-Path $repoRoot 'CollectionPublisher.psm1') $Root -Force
Copy-Item (Join-Path $repoRoot 'site') $Root -Recurse -Force

if (-not (Test-Path (Join-Path $Root 'snapshot.json'))) {
    throw "No snapshot.json in $Root - run tests\make-snapshot.ps1 against a Playnite backup first (see README)."
}

# --- a throwaway git repo with a bare remote -------------------------------
if (Test-Path $site) { Remove-Item $site -Recurse -Force }
if (Test-Path $remote) { Remove-Item $remote -Recurse -Force }
New-Item -ItemType Directory -Path $site -Force | Out-Null
git -C $site init -q -b main
git -C $site config user.email 'test@example.com'
git -C $site config user.name 'Test'
Set-Content -LiteralPath (Join-Path $site 'README.md') -Value '# temp'
git -C $site add -A
git -C $site commit -q -m 'init'
git init -q --bare $remote
git -C $site remote add origin $remote
git -C $site push -q -u origin main

# --- run the publish (same call the background runspace makes) --------------
$global:PlayniteApi = [pscustomobject]@{
    Paths         = [pscustomobject]@{ ExtensionsDataPath = $env:TEMP }
    Dialogs       = [pscustomobject]@{ ShowMessage = { param($m, $t, $b) 'No' } }
    Notifications = [pscustomobject]@{ Add = { param($a, $b, $c) }; Remove = { param($a) } }
    Database      = [pscustomobject]@{
        Games = @(); Sources = @(); Genres = @(); Features = @(); Tags = @()
        Platforms = @(); Companies = @(); Series = @(); CompletionStatuses = @()
    }
}

Import-Module (Join-Path $Root 'CollectionPublisher.psm1') -Force -WarningAction SilentlyContinue
$module = Get-Module CollectionPublisher
& $module { param($d) Set-GfnDataDir -Path $d } $data

$snapshot = Get-Content -LiteralPath (Join-Path $Root 'snapshot.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$snapshot = @($snapshot)

$settings = [pscustomobject]@{
    SitePath      = $site
    SiteUrl       = 'https://example.test'
    Push          = $true
    CommitMessage = 'update library'
    AccessBySource = @{ 'Steam' = 'owned' }
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$result = & $module { param($g, $s) Invoke-GfnCheckCore -GameList $g -ForceRefresh | Out-Null } $snapshot
$core = & $module { param($g) Invoke-GfnCheckCore -GameList $g } $snapshot
$publish = & $module { param($r, $s) Publish-SiteData -Result $r -SitePath $s.SitePath -Push -CommitMessage $s.CommitMessage } $core $settings
"worker exit=0 in $([int]$sw.Elapsed.TotalSeconds)s"

# --- checks -----------------------------------------------------------------
"stats: " + (($core.stats.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')
"publish: $($publish.message) (pushed=$($publish.pushed))"
"site files: " + ((Get-ChildItem $site -File | ForEach-Object Name) -join ', ')

$gamesJson = Join-Path $site 'data\games.json'
"games.json: $([Math]::Round((Get-Item $gamesJson).Length / 1KB)) KB"
$doc = Get-Content -LiteralPath $gamesJson -Raw | ConvertFrom-Json
"games: $($doc.Games.Count)  gamePass: $($doc.GamePass.Count)  generated: $($doc.GeneratedAt)"

"git log:"
git -C $site log --oneline
"remote has commit: $(git -C $remote rev-parse --short HEAD 2>$null)"
"remote tree: " + ((git -C $remote ls-tree -r --name-only HEAD) -join ', ')
