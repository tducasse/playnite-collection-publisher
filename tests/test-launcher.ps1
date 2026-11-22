# Tests launcher resolution (store source + Playnite game id + store package).
# No Playnite and no network needed.
param([string]$ModulePath = (Join-Path $PSScriptRoot '..\CollectionPublisher.psm1'))

$ErrorActionPreference = 'Stop'

Import-Module $ModulePath -Force -WarningAction SilentlyContinue
$module = Get-Module CollectionPublisher
if (-not $module) { $module = Get-Module GFNCheck }
if (-not $module) { throw "Could not load $ModulePath" }

$script:failures = 0
function global:Check($name, $actual, $expected) {
    $ok = ($actual -eq $expected)
    if (-not $ok) { $script:failures++ }
    $mark = if ($ok) { 'ok  ' } else { 'FAIL' }
    Write-Host ("{0} {1}: expected '{2}', got '{3}'" -f $mark, $name, $expected, $actual)
}

& $module {
    # Source names are the launcher, except for the Microsoft Store ones.
    Check 'steam source'               (Get-GameLauncher -Source 'Steam' -GameId '292030') 'Steam'
    Check 'epic source'                (Get-GameLauncher -Source 'Epic' -GameId 'abc') 'Epic'
    Check 'ea app source'              (Get-GameLauncher -Source 'EA app' -GameId 'DR:225064100') 'EA'
    Check 'ubisoft connect source'     (Get-GameLauncher -Source 'Ubisoft Connect' -GameId '5210') 'Ubisoft'
    Check 'battle.net source'          (Get-GameLauncher -Source 'Battle.net' -GameId 'WTCG') 'Battle.net'

    # Microsoft Store sources: the game id names the real package/offer.
    Check 'gp source + OFB-EAST id'    (Get-GameLauncher -Source 'Xbox Game Pass' -GameId 'OFB-EAST:52699') 'EA'
    Check 'gp source + Origin id'      (Get-GameLauncher -Source 'Xbox Game Pass' -GameId 'Origin.OFR.50.0004992') 'EA'
    Check 'xbox source + MS package'   (Get-GameLauncher -Source 'Xbox' -GameId 'Microsoft.Chelan_8wekyb3d8bbwe') 'Xbox'
    Check 'xbox source + EA publisher' (Get-GameLauncher -Source 'Xbox Game Pass' -GameId 'unknown' -Publishers @('Electronic Arts')) 'EA'
    Check 'xbox source + EA in list'   (Get-GameLauncher -Source 'Xbox Game Pass' -GameId 'unknown' -Publishers @('EA', 'Numskull Games')) 'EA'
    Check 'xbox source + other pub'    (Get-GameLauncher -Source 'Xbox' -GameId '' -Publishers @('Coffee Stain Publishing')) 'Xbox'

    # Store packages: the stub that starts the publisher's launcher.
    Check 'package EA'                 (Get-LauncherFromPackage 'ElectronicArtsMobile.Rosebud-Battlefield2042_q5ha1ztykcgvj') 'EA'
    Check 'package Ubisoft'            (Get-LauncherFromPackage 'Ubisoft.PC-Discovery_ngz4m417e0mpw') 'Ubisoft'
    Check 'package Blizzard'           (Get-LauncherFromPackage 'BlizzardEntertainmentInc.DiabloIV_q5ha1ztykcgvj') 'Battle.net'
    Check 'package Riot'               (Get-LauncherFromPackage 'RiotGames.VALORANT_q5ha1ztykcgvj') 'Riot'
    Check 'package Microsoft'          (Get-LauncherFromPackage 'Microsoft.624F8B84B80_8wekyb3d8bbwe') 'Xbox'
    Check 'package empty'              (Get-LauncherFromPackage '') $null

    # Catalogue rows: EA Play wins over everything, then package, then publisher.
    Check 'product EA Play'            (Get-ProductLauncher -Product ([pscustomobject]@{ IsEaPlay = $true; Package = ''; Publisher = 'Ubisoft' })) 'EA'
    Check 'product Ubisoft package'    (Get-ProductLauncher -Product ([pscustomobject]@{ IsEaPlay = $false; Package = 'Ubisoft.PCAnno1800_ngz4m417e0mpw'; Publisher = 'Ubisoft' })) 'Ubisoft'
    Check 'product no package'         (Get-ProductLauncher -Product ([pscustomobject]@{ IsEaPlay = $false; Package = ''; Publisher = 'Ubisoft' })) 'Ubisoft'
    Check 'product native package'     (Get-ProductLauncher -Product ([pscustomobject]@{ IsEaPlay = $false; Package = 'Microsoft.HaloInfinite_8wekyb3d8bbwe'; Publisher = 'Xbox Game Studios' })) 'Xbox'
    Check 'product unknown'            (Get-ProductLauncher -Product ([pscustomobject]@{ IsEaPlay = $false; Package = ''; Publisher = '' })) 'Xbox'
}

if ($script:failures -gt 0) {
    Write-Host ("{0} check(s) failed" -f $script:failures)
    exit 1
}
Write-Host 'All launcher checks passed'
