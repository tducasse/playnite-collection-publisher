# Playnite collection publisher

Publishes your Playnite library as a static site, and marks every game with its
**GeForce NOW** status: playable, playable after a manual step, or not at all.

```
Playnite  ──snapshot──▶  matching + site  ──git push──▶  Netlify/Vercel/Pages
```

Written for a specific, slightly awkward question: *"I have games spread over
Steam, Epic, GOG, Ubisoft, EA, Battle.net, Xbox and Game Pass — which of them can
I actually play on GeForce NOW tonight, and what do I have to click first?"*

## What it produces

A static site (no backend, no CDN, no build step) with:

- **one row per game**, not per purchase — a title owned on Steam *and* available
  via Game Pass is one line showing both routes
- **two independent labels per game**: the launcher it really starts from
  (`Steam`, `Epic`, `GOG`, `EA`, `Ubisoft`, `Xbox`, `Battle.net`, `Riot`, `itch`)
  and, separately, `Game Pass` when the title is in the catalogue. An EA Play
  title reads `EA` + `Game Pass`, not "EA app + gamepass"
- a **segmented filter**: `All` / `On GFN` / `Not on GFN`, plus genre and store
- **one click per game** opens its store page (Steam/Epic/GOG/itch from Playnite
  metadata, the Microsoft Store page for Game Pass titles built from the product id)
- **sorting**: A–Z, best critics, best community, newest
- a **search box** that answers "do I have this?" and "can I stream it?"
- shareable URLs (`#gfn=yes&genre=Racing`), dark mode, phone-friendly

## Why GeForce NOW needs help

NVIDIA's catalogue is per **store**, not per title: *Batman: Arkham Knight* is on
GeForce NOW for Steam and Epic, not for Xbox, so a Game Pass copy can't stream.
And the client only sees licences it can detect:

| GFN connector | behaviour |
| --- | --- |
| Steam, Ubisoft, Battle.net, GOG, Xbox | "N games synced" — automatic |
| **Epic** | "Game library sync — Not supported": you must *Mark as owned* per game |
| **EA** | not a connector: the licence must exist in your EA account first (Game Pass EA Play games need adding in the EA app), then *Mark as owned* |

The extension encodes that per store (`SyncByStore` in `settings.json`) and shows a
badge on the rows that need a click.

## Requirements

- Playnite 10 or 11 (Windows), with your store libraries already synced
- PowerShell 5.1 (ships with Windows)
- git in `PATH` (only if you want it to push)
- Optional: PC Game Pass, for the Game Pass catalogue and entitlement checks

## Install

Copy the folder to `%APPDATA%\Playnite\Extensions\CollectionPublisher\`:

```
CollectionPublisher\extension.yaml
CollectionPublisher\CollectionPublisher.psm1
CollectionPublisher\site\{index.html,app.js,styles.css}
```

Restart Playnite. Script extensions are loaded at startup — check
`%APPDATA%\Playnite\extensions.log` for `Loaded script extension`.

## Use

- **Main menu → Extensions → Collection publisher settings** — pick the folder of
  your site repo and whether to `git push`.
- **Main menu → Extensions → Publish collection** — does everything. The work runs
  in a background runspace, so the UI never freezes; progress shows as a Playnite
  notification.

The first run asks for the folder if it isn't configured, and copies the site
templates into it *only if they are missing* — an existing site is never
overwritten.

> There is deliberately **no hook on library update**: Playnite runs script
> extensions with `PSThreadOptions.UseCurrentThread`, so a `DispatcherTimer`
> callback cannot run a scriptblock — it throws *"There is no Runspace available
> to run scripts in this thread"* and takes Playnite down. That's why this uses a
> runspace of its own instead of timers.

## Configure

`%APPDATA%\Playnite\ExtensionsData\CollectionPublisher_<id>\settings.json`:

```json
{
  "SitePath": "C:\\path\\to\\your\\site-repo",
  "SiteUrl": "https://example.com",
  "Push": true,
  "CommitMessage": "update library",
  "AccessBySource": {
    "Steam": "owned", "Epic": "owned", "GOG": "owned", "Battle.net": "owned",
    "itch.io": "owned", "Humble": "owned", "Riot Games": "owned",
    "Steam Family Sharing": "shared",
    "Xbox Game Pass": "gamepass", "Xbox": "gamepass",
    "EA app": "gamepass", "Ubisoft Connect": "gamepass"
  },
  "SyncByStore": { "Epic": "mark" }
}
```

- `AccessBySource` — *owned* vs *subscription access*. PC Game Pass entitles games
  that run in other launchers, so `EA app`/`Ubisoft Connect` are `gamepass` here,
  not "EA Play"/"Ubisoft+".
- `Owned` — a store licence never says *why* you have it. Games in the EA Play
  catalogue are treated as entitlements; anything else in the EA app is a
  purchase. For the rest (EA Play titles you actually bought, Ubisoft, Xbox) list
  the title here and it is shown as owned:

  ```json
  "Owned": ["It Takes Two", "Star Wars Outlaws"]
  ```
- `SyncByStore` — `auto` (default), `mark` (*Mark as owned* in GFN), or
  `claim+mark`. Set it per store to match what GFN's *Game store accounts* screen
  says about your connectors.

## What gets written

`<SitePath>/data/games.json` — one file, ~1.7 MB, ~200 KB gzipped:

```jsonc
{
  "generatedAt": "…", "catalog": { "country": "GB", "titles": 6347 },
  "stats": { "streamable": 522, "notStreamable": 1816, … },
  "games": [ { "name": "Hades", "store": "Steam", "launcher": "Steam",
               "access": "owned",
               "gfn": "yes|other|no|na", "gfnStores": ["STEAM"],
               "sync": "auto|mark|claim+mark", "releaseDate": "2020-09-17",
               "criticScore": 92, "links": [ { "name": "Steam", "url": "…" } ], … } ],
  "gamePass": [ { "name": "Hades II", "launcher": "Xbox", "gfn": "no", … } ]
}
```

The site needs nothing else — it merges `games` and `gamePass` itself, so the same
data can feed any other front-end.

## How matching works

NVIDIA's catalogue comes from the same endpoint the GeForce NOW site uses
(`api-prod.nvidia.com/services/gfngames/v1/gameList`, GraphQL), including the
per-store variants of every app. PC Game Pass comes from
`catalog.gamepass.com` + `displaycatalog.mp.microsoft.com`.

Titles are compared as `(normalised title, store)`:

- trademark glyphs stripped **before** Unicode folding (`™` otherwise becomes `TM`)
- editions/platform noise dropped (`Deluxe`, `GOTY`, `Windows`, `Cross-Gen`, …)
- bare numbers kept — stripping years turns `Cyberpunk 2077` into `cyberpunk`
- a stricter second key flags "same game, different edition" matches
- `overrides.json` (in the extension data folder) for manual corrections

On a 1,900-game library this resolves 99%+ exactly; GFN's own per-connector counts
(121 Steam, 58 Ubisoft, 1 GOG, 196 Xbox) match the computed numbers within a few
titles.

### Which launcher a game starts from

`store` is the Playnite source. `launcher` is what pressing *Play* actually
starts, and they are not the same thing: Game Pass hands some titles to another
publisher. The Microsoft Store build of an EA Play or Ubisoft game is a ~10 MB
stub that installs and starts the EA app or Ubisoft Connect, while the Xbox app
shows it as a normal install. Static, in order of trust:

| evidence | reads as |
| --- | --- |
| EA Play list (`1d33fbb9…`) | `EA`, always |
| product `Properties.PackageFamilyName` | `ElectronicArtsMobile.*` → `EA`, `Ubisoft.*` → `Ubisoft`, `Blizzard*` → `Battle.net`, `Riot*` → `Riot`, anything else → `Xbox` |
| Playnite game id of an MS Store row | `Origin.OFR…` / `OFB-EAST:…` → `EA`, `Microsoft.*_8wekyb3d8bbwe` → `Xbox` |
| publisher | `Electronic Arts` → `EA`, `Ubisoft` → `Ubisoft`, `Blizzard` → `Battle.net`, `Riot Games` → `Riot` |
| source name | `Steam`, `Epic`, `GOG`, `itch.io`, `Battle.net`, `Riot Games`, `EA app`, `Ubisoft Connect` |

Catalogue entries are often bundles; the package lives on the product they
bundle, so one extra request follows `BundledSkus` (this resolves a package for
605/605 titles). The package is cached in `gamepass-details.json`; a cache
written before the `Package` field existed is refilled on the next run.

The site applies the same rules as a fallback (`launcher`, else game id, else
publisher), so an existing `games.json` renders correctly without a republish.

`Game Pass` is a second, independent label, and it is shown only when the title
is really in the catalogue *today* - the source name and `access` field are not
evidence. `access: gamepass` just means "the licence came from a subscription":
a Ubisoft Connect game that left Game Pass is `Ubisoft`, Apex Legends is `EA`,
and Deep Rock Galactic (Playnite's "Xbox Game Pass" source) is `Xbox`.

Catalogue membership is tested with the same normalisation as the GFN matcher,
plus the SKU suffixes the store adds (`Year 2 Edition`, `Revolution`, `Maximum
Edition`, `EA Play Edition`, `for Windows + Launcher`, `(PC)`, …), so a library
copy of `Battlefield V` meets `Battlefield™ V Year 2 Edition`. Equality is still
required on the whole key, so `Doom` does not meet `Doom Eternal`.

Consequence for the site's filter: `Everything` / `I own it` / `On Game Pass`
overlap on purpose (a game you own can also be in Game Pass), so the option
labels carry live counts, and a licensed-but-not-in-Game-Pass title appears under
`Everything` only.

## Development

```
tests/
  make-snapshot.ps1   unzipped Playnite backup -> snapshot.json (for offline runs)
  test-snapshot.ps1   library reader against a mock Playnite API
  test-settings.ps1   settings round-trip
  test-publish.ps1    snapshot -> matching -> games.json -> git commit + push
  test-background.ps1 Start-Publish in a background runspace (the crash path)
  test-launcher.ps1   launcher resolution (source, game id, store package)
  check-catalog.ps1   live Game Pass catalogue -> packages -> launchers
```

```powershell
# 1. Unzip a Playnite backup somewhere, then:
powershell -File tests\make-snapshot.ps1 -LibraryDir C:\path\to\backup\library

# 2. Run the pipeline against a throwaway git repo:
powershell -File tests\test-publish.ps1

# 3. Or just the crash-path test (works without a real library):
powershell -File tests\test-background.ps1 -ModulePath .\CollectionPublisher.psm1
```

### PowerShell 5.1 traps this code works around

- `Invoke-RestMethod` decodes JSON as ISO-8859-1 when the server omits `charset`,
  mangling every `®`/`™` → use the bundled `Invoke-Utf8Request`.
- `@()` on a `List[object]` throws *Argument types do not match* → `.ToArray()`.
- `ConvertTo-Json` collapses one-element arrays to scalars → the site's `asArray()`.
- `ConvertFrom-Json` emits a whole array as a single object → wrap after assignment.
- Save `.psm1`/`.ps1` as **UTF-8 with BOM** or 5.1 reads them as ANSI.

## Licence

MIT.
