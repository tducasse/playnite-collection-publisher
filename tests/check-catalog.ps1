# End-to-end check of the Game Pass catalogue + launcher resolution, no Playnite.
param([string]$ModulePath = (Join-Path $PSScriptRoot '..\CollectionPublisher.psm1'))

$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force -WarningAction SilentlyContinue
$module = Get-Module CollectionPublisher
if (-not $module) { $module = Get-Module GFNCheck }

$dataDir = Join-Path $env:TEMP 'gfn-gp-test'
if (Test-Path -LiteralPath $dataDir) { Remove-Item -LiteralPath $dataDir -Recurse -Force }
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

$timer = [System.Diagnostics.Stopwatch]::StartNew()
$products = & $module { param($dir)
    $script:DataDirOverride = $dir
    @(Get-GamePassCatalog)
} $dataDir
$timer.Stop()

Write-Host ("fetched {0} titles in {1:n1}s" -f $products.Count, $timer.Elapsed.TotalSeconds)
$withPackage = @($products | Where-Object { $_.Package }).Count
Write-Host ("package resolved for {0} of {1}" -f $withPackage, $products.Count)

$byLauncher = & $module { param($items)
    $items | Group-Object { Get-ProductLauncher -Product $_ } | Sort-Object Count -Descending |
        ForEach-Object { [pscustomobject]@{ Launcher = $_.Name; Count = $_.Count } }
} $products
$byLauncher | Format-Table -AutoSize | Out-String | Write-Host

& $module { param($items)
    foreach ($name in 'Anno 1800', 'Brawlhalla', 'Halo Infinite', 'Battlefield 4', 'Diablo IV', 'VALORANT', 'Brotato') {
        $p = @($items | Where-Object { $_.Title -eq $name }) | Select-Object -First 1
        if ($p) {
            Write-Host ("{0,-24} pkg={1,-45} ea={2,-5} launcher={3}" -f $p.Title, $p.Package, $p.IsEaPlay, (Get-ProductLauncher -Product $p))
        }
    }
} $products

# second call must come from the cache, not the network
$timer = [System.Diagnostics.Stopwatch]::StartNew()
$cached = & $module { param($dir) $script:DataDirOverride = $dir; @(Get-GamePassCatalog) } $dataDir
$timer.Stop()
Write-Host ("cached read: {0} titles in {1:n2}s" -f $cached.Count, $timer.Elapsed.TotalSeconds)
Write-Host ("details file: {0:n0} KB" -f ((Get-Item -LiteralPath (Join-Path $dataDir 'gamepass-details.json')).Length / 1KB))
