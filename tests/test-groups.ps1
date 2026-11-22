# Tests game identity: the group key, the groups.json pins, and the stamping.
# No Playnite and no network needed.
param([string]$ModulePath = (Join-Path $PSScriptRoot '..\CollectionPublisher.psm1'))

$ErrorActionPreference = 'Stop'

Import-Module $ModulePath -Force -WarningAction SilentlyContinue
$module = Get-Module CollectionPublisher
if (-not $module) { $module = Get-Module GFNCheck }
if (-not $module) { throw "Could not load $ModulePath" }

$dataDir = Join-Path $env:TEMP ('gfn-groups-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

$script:failures = 0
function global:Check($name, $actual, $expected) {
    $ok = ($actual -eq $expected)
    if (-not $ok) { $script:failures++ }
    $mark = if ($ok) { 'ok  ' } else { 'FAIL' }
    Write-Host ("{0} {1}: expected '{2}', got '{3}'" -f $mark, $name, $expected, $actual)
}

try {
    & $module { param($d) Set-GfnDataDir -Path $d } $dataDir

    & $module {
        # Same game, different store names -> one key.
        Check 'title'           (ConvertTo-GroupKeyRaw 'For Honor') 'for honor'
        Check 'standard suffix' (ConvertTo-GroupKeyRaw 'For Honor Standard') 'for honor'
        Check 'ampersand'       (ConvertTo-GroupKeyRaw 'Heroes of Might & Magic III Complete Edition') 'heroes might and magic 3'
        Check 'and + edition'   (ConvertTo-GroupKeyRaw 'Heroes of Might and Magic 3 - Complete Edition') 'heroes might and magic 3'
        Check 'year N'          (ConvertTo-GroupKeyRaw 'Battlefield V Year 2 Edition') 'battlefield 5'
        Check 'plain sequel ok' (ConvertTo-GroupKeyRaw 'Battlefield V') 'battlefield 5'
        Check 'hunter edition'  (ConvertTo-GroupKeyRaw 'Crysis 3 Hunter Edition') 'crysis 3'
        Check 'ultimate'        (ConvertTo-GroupKeyRaw 'Control Ultimate Edition') 'control'
        Check 'trademark digit' (ConvertTo-GroupKeyRaw 'Watch Dogs®2') 'watch dogs 2'
        Check 'paren year'      (ConvertTo-GroupKeyRaw 'Beneath a Steel Sky (1994)') 'beneath a steel sky'
        Check 'year edition'    (ConvertTo-GroupKeyRaw 'Sea of Thieves: 2026 Edition') 'sea thieves'
        Check 'for windows'     (ConvertTo-GroupKeyRaw 'Minecraft Dungeons for Windows + Launcher') 'minecraft dungeons'
        Check 'sequel stays'    (ConvertTo-GroupKeyRaw 'Doom Eternal') 'doom eternal'
        Check 'sequel differs'  ((ConvertTo-GroupKeyRaw 'Doom') -eq (ConvertTo-GroupKeyRaw 'Doom Eternal')) $false
        Check 'empty'           (ConvertTo-GroupKeyRaw '') ''

        # Pins from groups.json (created with the defaults on first use).
        $aliases = Get-GroupAliases
        $script:GroupAliases = $aliases
        Check 'default pins'    $aliases.Count 5
        Check 'alias monopoly'  (Get-GroupKey 'NEW MONOPOLY') 'monopoly'
        Check 'alias valiant'   (Get-GroupKey 'Valiant Hearts: The Great War') 'valiant hearts'
        Check 'alias siege'     (Get-GroupKey "Tom Clancy's Rainbow Six® Siege - Elite Edition") 'tom clancy s rainbow six siege'
        Check 'alias cry'       (Get-GroupKey "Assassin's Creed Freedom Cry - Standalone") 'assassin s creed freedom cry'

        # A pin added later wins, and both sides are keyed the same way.
        $path = Join-Path (Get-GfnDataDir) 'groups.json'
        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $json | Add-Member -NotePropertyName 'GTA V' -NotePropertyValue 'Grand Theft Auto 5' -Force
        ConvertTo-Json -InputObject $json | Set-Content -LiteralPath $path -Encoding UTF8
        $script:GroupAliases = Get-GroupAliases
        Check 'user pin'        (Get-GroupKey 'GTA V') (ConvertTo-GroupKeyRaw 'Grand Theft Auto 5')

        # Stamping a publish: library rows and catalogue rows share the key.
        $rows = @(
            [pscustomobject]@{ name = 'For Honor'; store = 'Ubisoft Connect' },
            [pscustomobject]@{ name = 'For Honor Standard'; store = 'Xbox Game Pass' },
            [pscustomobject]@{ name = 'Doom'; store = 'Steam' }
        )
        $groups = Set-GameGroup -Rows $rows
        Check 'group count'     $groups 2
        Check 'lib group'       $rows[0].group 'for honor'
        Check 'catalogue group' $rows[1].group 'for honor'
        Check 'other group'     $rows[2].group 'doom'
    }
} finally {
    Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) {
    Write-Host ("{0} check(s) failed" -f $script:failures)
    exit 1
}
Write-Host 'All identity checks passed'
