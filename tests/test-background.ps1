# Reproduces the crash scenario: Start-Publish runs the publish in a background
# runspace while the caller keeps running. Mocks are plain C# (no scriptblocks),
# because a ScriptMethod bound to one runspace cannot be called from another.
param([string]$ModulePath, [switch]$ForceRefresh, [string]$GamesPath)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName WindowsBase, PresentationFramework

Add-Type -TypeDefinition @"
using System;
using System.Collections;
using System.Collections.Generic;

public class FakeGame {
    public Guid Id; public string Name; public Guid SourceId; public bool Hidden;
    public string Source; public List<Guid> FeatureIds = new List<Guid>();
}
public class FakeGames : ArrayList {
    public int UpdateCount = 0;
    public FakeGame this[Guid id] { get { foreach (FakeGame g in this) if (g.Id == id) return g; return null; } }
    public void BeginBufferUpdate() { }
    public void EndBufferUpdate() { }
    public void Update(object g) { UpdateCount++; }
}
public class FakeSource { public Guid Id; public string Name; }
public class FakeFeature { public Guid Id = Guid.NewGuid(); public string Name; }
public class FakeFeatures : IEnumerable {
    public List<FakeFeature> Items = new List<FakeFeature>();
    public FakeFeature Add(string name) { var f = new FakeFeature(); f.Name = name; Items.Add(f); return f; }
    public IEnumerator GetEnumerator() { return Items.GetEnumerator(); }
}
public class FakeNotifications {
    public List<string> Log = new List<string>();
    public void Add(string id, string text, string type) { Log.Add(type + ": " + text); }
    public void Remove(string id) { }
}
public class FakeDialogs {
    public string LastMessage = "";
    public string ShowMessage(string text, string caption, object button) { LastMessage = text; return "No"; }
    public string SelectFolder(string initial) { return initial; }
}
"@

# Uses a real library snapshot if given, otherwise a small synthetic one so the
# test runs on a clean machine.
if (-not $GamesPath) { $GamesPath = Join-Path $env:TEMP 'gfncheck\games.json' }
if (Test-Path $GamesPath) {
    $data = Get-Content -LiteralPath $GamesPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    $titles = @('Hades','Hades II','Cyberpunk 2077','Fortnite','Dota 2','Counter-Strike 2',
                'Apex Legends','Baldur''s Gate 3','Elden Ring','Stardew Valley')
    $stores = @('Steam','Epic','GOG','Ubisoft Connect','EA app','Battle.net','Xbox','itch.io')
    $data = 1..40 | ForEach-Object {
        [pscustomobject]@{
            name  = $titles[$_ % $titles.Count] + $(if ($_ -gt $titles.Count) { " $_" } else { '' })
            store = $stores[$_ % $stores.Count]
            access = 'owned'; hidden = $false
        }
    }
    "using synthetic library ($($data.Count) games)"
}
$games = New-Object FakeGames
$sources = New-Object 'System.Collections.Generic.List[FakeSource]'
$seen = @{}
foreach ($g in @($data)) {
    if (-not $seen.ContainsKey([string]$g.Source)) {
        $seen[[string]$g.Source] = $true
        $s = New-Object FakeSource
        $s.Id = [Guid]::NewGuid(); $s.Name = [string]$g.Source
        $sources.Add($s)
    }
}
foreach ($g in @($data)) {
    $game = New-Object FakeGame
    $game.Id = [Guid]::NewGuid(); $game.Name = $g.Name; $game.SourceId = [Guid]::NewGuid()
    $game.Hidden = [bool]$g.Hidden; $game.Source = $g.Source
    $games.Add($game) | Out-Null
}
$features = New-Object FakeFeatures

$global:PlayniteApi = [pscustomobject]@{
    Paths         = [pscustomobject]@{ ExtensionsDataPath = $env:TEMP }
    Dialogs       = New-Object FakeDialogs
    Notifications = New-Object FakeNotifications
    Database      = [pscustomobject]@{ Games = $games; Sources = $sources; Features = $features }
}

Import-Module $ModulePath -Force -WarningAction SilentlyContinue
$module = Get-Module CollectionPublisher

# point settings at a scratch site folder
$site = Join-Path $env:TEMP 'bg-site'
if (Test-Path $site) { Remove-Item $site -Recurse -Force }
$settings = & $module { Get-PublishSettings }
$settings.SitePath = $site
$settings.Push = $false
& $module { param($s) Save-PublishSettings -Settings $s } $settings

$sw = [System.Diagnostics.Stopwatch]::StartNew()
Start-Publish -ForceRefresh:$ForceRefresh
$returned = $sw.ElapsedMilliseconds
"Start-Publish returned after $returned ms (UI thread free)"

# Prove the caller is not blocked: this loop runs while the publish is working.
$ticks = 0
while (Test-PublishRunning -and $sw.Elapsed.TotalMinutes -lt 5) {
    $ticks++
    Start-Sleep -Milliseconds 250
}
"caller kept running for $ticks ticks while publishing ($([int]$sw.Elapsed.TotalSeconds)s)"

"games updated : $($games.UpdateCount)"
"features      : $((($features.Items | ForEach-Object { $_.Name }) -join ' + '))"
"site files    : $((Get-ChildItem $site -File -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', ')"
"games.json    : $(Test-Path (Join-Path $site 'data\games.json'))"
"notifications :"
$global:PlayniteApi.Notifications.Log | Select-Object -Unique | ForEach-Object { "   $_" }
