# CryptoTicker

A DankMaterialShell (DMS) bar widget that shows live cryptocurrency prices from
the CoinGecko public API. Ported from the GNOME Shell extension
`crypto-ticker@ntxinh`.

## Features

- Scrolling marquee when prices exceed the configured ticker width
- Per-coin symbol colors (BTC, ETH, USDT, SOL, BNB, DOGE; others get a default color)
- 24h price change with up/down/flat coloring (hidden for USDT)
- Click the pill to force an immediate refresh
- Horizontal and vertical bar layouts
- Multi-monitor safe: market data is shared via `PluginService` globals, and a
  `fetching` gate plus process debounce ensure only one `curl` runs per interval
- Failure resilient: on HTTP/network errors the pill keeps last-known prices;
  HTTP 429 triggers exponential backoff (capped at 15 min)

## Requirements

- DMS >= 1.4.0 (plugin API, `PluginComponent`, `PluginService` globals)
- `curl` in `PATH`
- Network access to `api.coingecko.com`

## Install

The plugin already lives in the user plugin directory:

```
~/.config/DankMaterialShell/plugins/CryptoTicker/
```

Verify DMS sees it:

```fish
dms plugins list
dms ipc plugins list
```

Then enable it in **Settings → Plugins → Crypto Ticker** (or it may already be
enabled via `plugin_settings.json`).

## Adding to the bar

**Settings → Widgets** → add `cryptoTicker` to a bar section (e.g.
`rightWidgets`). The pill appears once the plugin is enabled and placed.

## Settings

Settings are edited in **Settings → Plugins → Crypto Ticker** and persisted to
`~/.config/DankMaterialShell/plugin_settings.json` under the `cryptoTicker` key.

| Key               | Type   | Default                     | Range / notes                                   |
|-------------------|--------|-----------------------------|-------------------------------------------------|
| `coins`           | string | `bitcoin,ethereum,tether`   | CoinGecko coin IDs, comma separated             |
| `currency`        | string | `usd`                       | CoinGecko `vs_currency` (usd, eur, vnd, jpy…)   |
| `refreshInterval` | int    | `300`                       | Seconds between fetches; UI slider 30–3600      |
| `tickerWidth`     | int    | `280`                       | Pill width in px; UI slider 120–600             |
| `marqueeEnabled`  | bool   | `true`                      | Scroll when content exceeds `tickerWidth`       |

Note: editing `plugin_settings.json` by hand is only picked up at shell
startup — use the Settings UI, or run `dms restart` after external edits.

## Debugging

```fish
# Is the plugin loaded?
dms ipc plugins status cryptoTicker
dms ipc plugins list

# Reload after changing plugin files
dms ipc plugins reload cryptoTicker

# Watch shell logs for fetch errors (WARN qml: CryptoTicker: ...)
journalctl --user -u dms.service -f | grep -i cryptoticker

# Inspect persisted plugin settings
jq '.cryptoTicker' ~/.config/DankMaterialShell/plugin_settings.json

# Widget visibility on the bar
dms ipc widget visibility cryptoTicker
```

Fetch failures surface as `crypto: <error>` in the pill when no data has been
loaded yet, and as `WARN qml: CryptoTicker: HTTP <code>` /
`Network error (exit N)` in the journal. Last-known prices stay visible while
errors are reported.

## Known limitations

- No popout/detail view — the widget is pill-only.
- Prices always render with a `$` prefix regardless of `currency`; the fiat
  selection only changes which CoinGecko `vs_currency` is requested.
- Marquee scrolling is horizontal-only; the vertical bar pill stacks coins
  statically.
- CoinGecko free tier rate-limits aggressive polling; keep `refreshInterval`
  at 30s or higher. HTTP 429 responses back off exponentially (max 15 min).
- The original extension's `panel-position` setting is superseded by DankBar
  widget layout — position is controlled by which bar section holds the widget.
- The original GNOME Shell extension at
  `~/.local/share/gnome-shell/extensions/crypto-ticker@ntxinh/` is untouched
  and independent of this port.
- Multi-monitor dedup relies on `PluginService` globals; verified logically —
  only one `curl` per interval across bar instances (single-monitor setup used
  for validation).
