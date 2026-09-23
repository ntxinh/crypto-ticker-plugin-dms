# CryptoTicker — DMS Plugin Design

**Date:** 2026-09-23
**Status:** Approved (in-chat design)
**Target:** DankMaterialShell 1.4.4 (installed at `/usr/share/quickshell/dms`), Quickshell 0.2.1, Niri, Fedora 44

## 1. Goal

Port the GNOME Shell extension `crypto-ticker@ntxinh` to a native DMS bar-widget plugin at `~/.config/DankMaterialShell/plugins/CryptoTicker/`, preserving its data source, formatting, marquee UX, and settings while adapting to the DMS/Quickshell plugin API. The original extension is not modified.

## 2. Source Analysis (what exists today)

| Aspect | Original implementation |
|---|---|
| Type | `PanelMenu.Button` indicator, `extension.js` (GJS) |
| Data | CoinGecko `GET /api/v3/coins/markets?vs_currency={cur}&ids={csv}&order=market_cap_desc&per_page=250&page=1&sparkline=false&price_change_percentage=24h` via Soup |
| Refresh | `GLib.timeout_add_seconds`, default 300s, min 5s |
| Render | `SYMBOL: $PRICE (±X.XX%)` segments joined by `   |   `; per-coin symbol colors (BTC `#f7931a`, ETH `#627eea`, USDT `#26a17b`, SOL `#9945ff`, BNB/DOGE `#f3ba2f`, default `#7fdbff`); change colors green `#2ecc71` / red `#e74c3c` / yellow `#f1c40f` / gray `#aaaaaa`; USDT omits % change |
| Price format | `< 1` → truncate (floor) to 2 decimals; `≥ 1` → floor to integer; `$` prefix hardcoded regardless of fiat |
| Marquee | 280px clipped `St.BoxLayout`; scrolls right→left at 1.5px/25ms (~60px/s) only when text wider than container +10px |
| Settings | `refresh-interval` (int), `coins` (CSV string), `currency` (string), `panel-position` (left/center/right) via GSettings + Adw prefs |
| Errors | Any failure replaces ticker with status text (`Network error`, `HTTP {status}`, `Invalid response`, `parse error`). No last-price retention, no overlap guard, no rate-limit handling |

## 3. GNOME → DMS API Mapping

| GNOME Shell | DMS plugin (verified against 1.4.4) |
|---|---|
| GJS / `extension.js` | QML `PluginComponent` (`CryptoTicker.qml`) + `CryptoTicker.js` helpers |
| `PanelMenu.Button` in panel box | `horizontalBarPill` / `verticalBarPill` inside `BasePill` (DankBar sections own placement) |
| `St.BoxLayout`/`St.Label` | `Row`/`Column`/`StyledText`, `Theme` colors |
| `Soup.Session` GET | `Proc.runCommand` + `curl` (DMS convention; no XHR in codebase) |
| `GLib.timeout_add_seconds` | `Timer { repeat: true; triggeredOnStart: true }` |
| `GLib.timeout_add` marquee tick | `NumberAnimation on x` (~60px/s, loops) |
| GSettings schema + `prefs.js` | `PluginSettings` + `StringSetting`/`SliderSetting`/`ToggleSetting`, auto-persisted to `settings.json` |
| `panel-position` setting | **Dropped** — DankBar layout (Settings → DankBar) controls section/placement |
| `Main.panel.addToStatusArea` lifecycle | Plugin enable/disable via PluginService; `Component.onCompleted` init |
| `console.error` → journal | `console.warn/error` → `qs` stdout/journal |

## 4. Architecture

```
~/.config/DankMaterialShell/plugins/CryptoTicker/
├── plugin.json               # manifest
├── CryptoTicker.qml          # PluginComponent: pills, timer, fetch, render model
├── CryptoTicker.js           # pure helpers (see §6)
├── CryptoTickerSettings.qml  # PluginSettings UI
└── README.md
```

### 4.1 `plugin.json`

```json
{
    "id": "cryptoTicker",
    "name": "Crypto Ticker",
    "description": "Scrolling cryptocurrency prices in the bar, powered by CoinGecko",
    "version": "1.0.0",
    "author": "ntxinh (DMS port)",
    "type": "widget",
    "capabilities": ["dankbar-widget"],
    "component": "./CryptoTicker.qml",
    "settings": "./CryptoTickerSettings.qml",
    "icon": "currency_bitcoin",
    "requires_dms": ">=1.4.0",
    "requires": ["curl"],
    "permissions": ["settings_read", "settings_write"]
}
```

### 4.2 Data flow

```
Timer (refreshInterval, triggeredOnStart)
  → dedup gate: skip if globalVar fetching==true or lastFetchTs fresh
  → setGlobalVar("fetching", true)
  → Proc.runCommand("cryptoTicker.fetch",
        ["curl","-sS","--connect-timeout","3","--max-time","8","--compressed",
         "-w","\n%{http_code}", url])
  → split trailing status line; parse JSON array
  → success: setGlobalVar("marketData", data), lastFetchTs=now, lastError="", backoff reset
  → failure: setGlobalVar("lastError", msg), keep marketData, backoff on 429
  → finally: setGlobalVar("fetching", false)
```

`Proc.runCommand` same-id debounce collapses simultaneous multi-instance launches; the `lastFetchTs`/`fetching` gate makes staggered instances share one fetch per interval. All pill instances render from `marketData` via `PluginGlobalVar`/`Connections` on `globalVarChanged` — reactive, no polling.

### 4.3 Rendering

- **Horizontal pill**: `Item` with `clip: true`, `implicitWidth: tickerWidth` (default 280), containing a `Row` of `StyledText` segments built from a `segments` model (`{symbol, symbolColor, price, change, changeColor, showChange, separator}`). Marquee: `NumberAnimation` on `x` from `tickerWidth` to `-contentWidth`, duration `= distance / 60px/s`, `loops: Infinite`, running only when `marqueeEnabled && contentWidth > tickerWidth + 10`.
- **Vertical pill**: `Column`, one compact row per coin (`SYM $PRICE`, `Theme.fontSizeSmall`), no marquee.
- Colors: per-coin symbol map preserved; change colors → `Theme.success` / `Theme.error` / `Theme.warning` / `Theme.surfaceVariantText`; price text → `Theme.surfaceText`; separator → `Theme.outline`.
- No popout. `pillClickAction` = manual refresh (`lastFetchTs = 0` → fetch).

### 4.4 Settings

| Key | Component | Default | Range/notes |
|---|---|---|---|
| `coins` | StringSetting | `bitcoin,ethereum,tether` | CoinGecko ids, CSV; parsed trim+filter |
| `currency` | StringSetting | `usd` | vs_currency; `$` prefix stays hardcoded (user decision) |
| `refreshInterval` | SliderSetting | `300` | slider 30–3600s; code clamps ≥5s. Floor raised from original 5s because CoinGecko free tier rate-limits aggressively |
| `tickerWidth` | SliderSetting | `280` | 120–600px |
| `marqueeEnabled` | ToggleSetting | `true` | off → static clipped row |

Widget reads settings via injected `pluginData` (auto-reloads on `pluginDataChanged`); changes take effect on next tick; `coins`/`currency` changes trigger immediate refetch.

### 4.5 Error handling

- curl exit≠0, HTTP≠200, or non-array JSON → `lastError` set, `marketData` **preserved** (last-known prices keep rendering; improvement over original per requirements).
- No data ever loaded → pill shows status text (`"crypto: {lastError}"`) instead of segments.
- HTTP 429 → backoff: effective interval ×2ⁿ (n = consecutive failures), cap 15min; reset on success.
- `--max-time 8` + Proc's 10s kill → no hangs; `fetching` flag → no overlap.
- No API keys exist; nothing secret logged. Response body logged truncated to 200 chars on HTTP errors (matches original).

## 5. `CryptoTicker.js` helpers (pure, unit-shaped)

- `parseCoins(csv)` → trimmed non-empty id array
- `buildUrl(coins, currency)` → CoinGecko markets URL (same params as original)
- `formatPrice(p)` → original truncate/floor rules, `$` prefix
- `symbolColor(symbol)` → per-coin color map
- `changeColor(change, Theme)` → theme-mapped up/down/flat/unknown color
- `buildSegments(coins, marketData, Theme)` → segment model for the Row

## 6. Validation & testing

1. `plugin.json` validated against `PLUGINS/plugin-schema.json` (python `jsonschema` or `jq` structural check).
2. `qmllint` on QML files if available; else careful import review (`qs.Common`, `qs.Widgets`, `qs.Services`, `qs.Modules.Plugins`, `Quickshell.Io` not needed — Proc wraps Process).
3. `dms plugins list` → plugin discovered.
4. `dms ipc plugins enable cryptoTicker` → loads without error; check `qs` log.
5. Add `cryptoTicker` to a DankBar section (Settings → DankBar or `dms ipc settings set`); pill renders live prices.
6. Refresh cadence: observe update timestamps; settings change → refetch.
7. Failure path: invalid coin id / network down → last-known prices retained, `lastError` logged; recovery on next success.
8. Vertical bar orientation → vertical pill renders.
9. Original extension untouched (separate directory, read-only use).

If the live session can't be driven from this environment, remaining manual steps are documented in README + final report.

## 7. README contents

Overview, features, requirements (DMS ≥1.4.0, curl), install (already in plugins dir; `dms plugins list`, Settings → Plugins → enable), adding to DankBar, settings reference table, debugging (`qs -v`, `dms ipc plugins status`, fish-compatible commands), known limitations (no popout, `$` hardcoded, marquee horizontal-only, CoinGecko free-tier rate limits, `panel-position` superseded by DankBar layout).

## 8. Reused / rewritten / removed

- **Reused verbatim (logic):** CoinGecko endpoint+params, coin parsing, price formatting rules, symbol color map, change-color semantics, USDT % suppression, marquee width/speed heuristics, settings keys+defaults.
- **Rewritten:** all UI (St→QML), HTTP (Soup→curl/Proc), timers (GLib→Timer/NumberAnimation), settings (GSettings/Adw→PluginSettings), lifecycle (Extension enable/disable→PluginService).
- **Removed:** `panel-position` (DankBar owns placement); error-text-replaces-ticker behavior (superseded by last-known retention).
- **Added:** multi-instance fetch dedup, 429 backoff, manual refresh on click, `tickerWidth`/`marqueeEnabled` settings.
