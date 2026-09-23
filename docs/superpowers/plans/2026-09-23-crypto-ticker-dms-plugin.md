# CryptoTicker DMS Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the GNOME extension `crypto-ticker@ntxinh` to a DMS 1.4.4 bar-widget plugin showing a scrolling CoinGecko price marquee in DankBar.

**Architecture:** One `type: "widget"` plugin in `~/.config/DankMaterialShell/plugins/CryptoTicker/`. A `PluginComponent` owns a `Timer`-driven fetch via `Proc.runCommand`+`curl`, deduplicated across bar instances through `PluginService` global vars; pills render a `segments` model built by pure JS helpers in `CryptoTicker.js`. Settings via `PluginSettings` auto-persisted components.

**Tech Stack:** QML (QtQuick, Quickshell), DMS plugin API (`PluginComponent`, `PluginSettings`, `PluginService`, `Proc`, `Theme`), curl, Node 22 `node --test` for helper tests.

**Spec:** `docs/superpowers/specs/2026-09-23-crypto-ticker-dms-plugin-design.md`

## Global Constraints

- Working dir / plugin dir: `~/.config/DankMaterialShell/plugins/CryptoTicker/` — all plugin files live here.
- NEVER modify the original extension at `~/.local/share/gnome-shell/extensions/crypto-ticker@ntxinh/`.
- DMS version: 1.4.4 at `/usr/share/quickshell/dms`; plugin API is experimental — use only APIs verified in the spec.
- `plugin.json` `id` is `cryptoTicker` (camelCase); all `PluginService` global vars and `Proc` ids are namespaced `cryptoTicker.*`.
- HTTP only via `Proc.runCommand` + `curl` — no `XMLHttpRequest`, no other fetch mechanism.
- Price prefix stays hardcoded `$` regardless of fiat (user decision).
- No popout; `pillClickAction` = manual refresh (user decision).
- Fish shell: avoid bash-only syntax in documented commands (`&&` is fine in fish ≥3.0).
- Commit after every task with `git -c user.email="dev@local" -c user.name="dev" commit` (repo has no configured identity).

## Review Focus

1. **CoinGecko returns a JSON object, not array** (e.g. `{"status":{"error_code":429,...}}` on rate limit) → must not crash or clear prices. Owned by `Ticker.parseResponse` — tested in Task 1.
2. **Empty/whitespace `coins` setting** → no fetch, status text shown. Owned by `Ticker.parseCoins` + QML gate — tested in Task 1, verified in Task 4.
3. **Price boundary exactly 1.0** → integer path (`$1`, not `$1.00`). Owned by `Ticker.formatPrice` — tested in Task 1.
4. **Configured coin missing from API response** (bad id) → that coin shows `unknown` price, others unaffected. Owned by `Ticker.buildSegments`/`findCoin` — tested in Task 1.
5. **curl stdout missing the `-w` status line** (empty body, proxy interference) → treated as invalid response, last-known kept. Owned by `Ticker.parseResponse` — tested in Task 1.
6. **Multi-monitor duplicate fetches** → `fetching`/`lastFetchTs` global-var gate; verified at runtime in Task 4 (no unit test possible).

---

### Task 1: Manifest + JS helpers + tests

**Files:**
- Create: `plugin.json`
- Create: `CryptoTicker.js`
- Create: `tests/helpers.test.mjs`

**Interfaces:**
- Produces (consumed by Task 2's QML):
  - `Ticker.parseCoins(csv: string) -> string[]`
  - `Ticker.buildUrl(coins: string[], currency: string) -> string`
  - `Ticker.formatPrice(price: number|null|undefined) -> string`
  - `Ticker.symbolColor(symbol: string) -> string` (hex)
  - `Ticker.changeColor(change: number|null, colors: {up,down,flat,unknown}) -> color`
  - `Ticker.buildSegments(coins: string[], marketData: array, colors) -> Array<{symbol, symbolColor, price, changeText, changeColor, showChange, separator}>`
  - `Ticker.parseResponse(stdout: string, exitCode: number) -> {ok: bool, status: number, data?: array, error?: string}`

- [ ] **Step 1: Write `plugin.json`**

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

- [ ] **Step 2: Validate manifest structure**

Run:
```bash
python3 - <<'EOF'
import json
schema = json.load(open("/usr/share/quickshell/dms/PLUGINS/plugin-schema.json"))
m = json.load(open("plugin.json"))
for k in schema["required"]:
    assert k in m, f"missing required field: {k}"
assert m["type"] in ("widget", "daemon", "launcher", "desktop")
assert isinstance(m["capabilities"], list) and m["capabilities"]
assert isinstance(m["permissions"], list)
print("manifest OK")
EOF
```
Expected: `manifest OK`

- [ ] **Step 3: Write the failing test**

`tests/helpers.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, "..", "CryptoTicker.js"), "utf8")
    .split("\n").filter(l => !l.startsWith(".pragma")).join("\n");
const T = eval(`(function(){ ${src}; return {parseCoins, buildUrl, formatPrice, symbolColor, changeColor, buildSegments, parseResponse}; })()`);

const colors = { up: "U", down: "D", flat: "F", unknown: "?" };

test("parseCoins trims and drops empties", () => {
    assert.deepEqual(T.parseCoins("bitcoin, ethereum ,,solana"), ["bitcoin", "ethereum", "solana"]);
    assert.deepEqual(T.parseCoins(""), []);
    assert.deepEqual(T.parseCoins(null), []);
});

test("buildUrl matches original CoinGecko query", () => {
    const u = T.buildUrl(["bitcoin", "ethereum"], "eur");
    assert.ok(u.startsWith("https://api.coingecko.com/api/v3/coins/markets?"));
    assert.ok(u.includes("vs_currency=eur"));
    assert.ok(u.includes("ids=bitcoin%2Cethereum"));
    assert.ok(u.includes("price_change_percentage=24h"));
    assert.ok(u.includes("sparkline=false"));
});

test("formatPrice preserves original rules", () => {
    assert.equal(T.formatPrice(65432.12), "$65,432");   // >=1: floor to integer
    assert.equal(T.formatPrice(1.0), "$1");             // boundary: integer path
    assert.equal(T.formatPrice(0.456), "$0.45");        // <1: truncate, not round
    assert.equal(T.formatPrice(null), "unknown");
    assert.equal(T.formatPrice(undefined), "unknown");
});

test("symbolColor map + default", () => {
    assert.equal(T.symbolColor("BTC"), "#f7931a");
    assert.equal(T.symbolColor("ETH"), "#627eea");
    assert.equal(T.symbolColor("XXX"), "#7fdbff");
});

test("changeColor maps sign to theme colors", () => {
    assert.equal(T.changeColor(1.5, colors), "U");
    assert.equal(T.changeColor(-2, colors), "D");
    assert.equal(T.changeColor(0, colors), "F");
    assert.equal(T.changeColor(null, colors), "?");
});

const market = [
    { id: "bitcoin", symbol: "btc", current_price: 65432.12, price_change_percentage_24h: 0.05 },
    { id: "tether", symbol: "usdt", current_price: 0.999, price_change_percentage_24h: -0.01 }
];

test("buildSegments renders known, missing, and USDT coins", () => {
    const segs = T.buildSegments(["bitcoin", "tether", "dogecoin"], market, colors);
    assert.equal(segs.length, 3);
    assert.equal(segs[0].symbol, "BTC");
    assert.equal(segs[0].price, "$65,432");
    assert.equal(segs[0].changeText, " (+0.05%)");
    assert.equal(segs[0].showChange, true);
    assert.equal(segs[0].separator, true);
    assert.equal(segs[1].symbol, "USDT");
    assert.equal(segs[1].showChange, false);            // USDT hides % change
    assert.equal(segs[2].symbol, "DOGECOIN");           // missing coin: id uppercased
    assert.equal(segs[2].price, "unknown");
    assert.equal(segs[2].showChange, false);
    assert.equal(segs[2].separator, false);
});

test("parseResponse handles success, errors, and malformed output", () => {
    const ok = T.parseResponse(JSON.stringify(market) + "\n200", 0);
    assert.equal(ok.ok, true);
    assert.equal(ok.data.length, 2);

    assert.equal(T.parseResponse("rate limited\n429", 0).status, 429);
    assert.equal(T.parseResponse('{"status":{"error_code":429}}\n200', 0).ok, false); // object, not array
    assert.equal(T.parseResponse("", 7).ok, false);                                    // curl failure
    assert.equal(T.parseResponse("garbage-no-status-line", 0).ok, false);              // missing status
    assert.equal(T.parseResponse("not json\n200", 0).ok, false);                       // bad JSON
});
```

- [ ] **Step 4: Run test to verify it fails**

Run: `node --test tests/`
Expected: FAIL — `Cannot find module '../CryptoTicker.js'` (file doesn't exist yet)

- [ ] **Step 5: Write `CryptoTicker.js`**

```js
.pragma library

var SYMBOL_COLORS = {
    "BTC": "#f7931a",
    "ETH": "#627eea",
    "USDT": "#26a17b",
    "SOL": "#9945ff",
    "BNB": "#f3ba2f",
    "DOGE": "#f3ba2f"
};
var DEFAULT_SYMBOL_COLOR = "#7fdbff";

function parseCoins(csv) {
    if (!csv)
        return [];
    return csv.split(",").map(function (s) { return s.trim(); }).filter(function (s) { return s.length > 0; });
}

function buildUrl(coins, currency) {
    var ids = encodeURIComponent(coins.join(","));
    return "https://api.coingecko.com/api/v3/coins/markets?vs_currency="
        + encodeURIComponent(currency || "usd")
        + "&ids=" + ids
        + "&order=market_cap_desc&per_page=250&page=1&sparkline=false&price_change_percentage=24h";
}

function formatPrice(price) {
    if (price === null || price === undefined || isNaN(Number(price)))
        return "unknown";
    var p = Number(price);
    if (p < 1) {
        var truncated = Math.floor(p * 100) / 100;
        return "$" + truncated.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    }
    return "$" + Math.floor(p).toLocaleString(undefined);
}

function symbolColor(symbol) {
    return SYMBOL_COLORS[symbol] || DEFAULT_SYMBOL_COLOR;
}

function changeColor(change, colors) {
    if (change === null || change === undefined || isNaN(Number(change)))
        return colors.unknown;
    if (change > 0)
        return colors.up;
    if (change < 0)
        return colors.down;
    return colors.flat;
}

function findCoin(marketData, coinId) {
    if (!marketData)
        return null;
    for (var i = 0; i < marketData.length; i++) {
        var d = marketData[i];
        if (d && d.id && d.id.toLowerCase() === coinId.toLowerCase())
            return d;
    }
    return null;
}

function buildSegments(coins, marketData, colors) {
    var segs = [];
    for (var i = 0; i < coins.length; i++) {
        var item = findCoin(marketData, coins[i]);
        var symbol = item && item.symbol ? item.symbol.toUpperCase() : coins[i].toUpperCase();
        var change = item ? item.price_change_percentage_24h : null;
        var changeStr = (change === null || change === undefined || isNaN(Number(change)))
            ? "unknown"
            : ((change >= 0 ? "+" : "") + Number(change).toFixed(2) + "%");
        segs.push({
            symbol: symbol,
            symbolColor: symbolColor(symbol),
            price: item && item.current_price !== null && item.current_price !== undefined ? formatPrice(item.current_price) : "unknown",
            changeText: " (" + changeStr + ")",
            changeColor: changeColor(change, colors),
            showChange: symbol !== "USDT" && item !== null,
            separator: i < coins.length - 1
        });
    }
    return segs;
}

// Parses "curl -w '\n%{http_code}'" output: body + trailing status line.
function parseResponse(stdout, exitCode) {
    if (exitCode !== 0)
        return { ok: false, status: 0, error: "Network error (exit " + exitCode + ")" };
    var out = stdout || "";
    var nl = out.lastIndexOf("\n");
    var status = NaN;
    var body = out;
    if (nl >= 0) {
        var tail = out.substring(nl + 1).trim();
        if (/^\d+$/.test(tail)) {
            status = parseInt(tail);
            body = out.substring(0, nl);
        }
    }
    if (isNaN(status))
        return { ok: false, status: 0, error: "Invalid response" };
    if (status !== 200)
        return { ok: false, status: status, error: "HTTP " + status };
    try {
        var data = JSON.parse(body);
        if (!Array.isArray(data))
            return { ok: false, status: status, error: "Invalid response" };
        return { ok: true, status: status, data: data };
    } catch (e) {
        return { ok: false, status: status, error: "Parse error" };
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `node --test tests/`
Expected: PASS — all 7 tests

- [ ] **Step 7: Commit**

```bash
git add plugin.json CryptoTicker.js tests/helpers.test.mjs
git -c user.email="dev@local" -c user.name="dev" commit -m "Add plugin manifest and ticker helpers"
```

---

### Task 2: `CryptoTicker.qml` widget

**Files:**
- Create: `CryptoTicker.qml`

**Interfaces:**
- Consumes: all `Ticker.*` functions from Task 1; `pluginData.{coins,currency,refreshInterval,tickerWidth,marqueeEnabled}` (written by Task 3's settings UI; safe defaults when absent); `PluginService.getGlobalVar/setGlobalVar`, `Proc.runCommand`.
- Produces: loadable widget component; global vars `cryptoTicker.{marketData,lastFetchTs,fetching,failCount,backoffUntil,lastError}`.

- [ ] **Step 1: Write `CryptoTicker.qml`**

```qml
import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "CryptoTicker.js" as Ticker

PluginComponent {
    id: root

    // Settings (pluginData auto-reloads on pluginDataChanged)
    property var coins: Ticker.parseCoins(pluginData.coins || "bitcoin,ethereum,tether")
    property string currency: pluginData.currency || "usd"
    property int refreshInterval: Math.max(5, pluginData.refreshInterval || 300)
    property int tickerWidth: pluginData.tickerWidth || 280
    property bool marqueeEnabled: pluginData.marqueeEnabled !== undefined ? pluginData.marqueeEnabled : true

    readonly property var changeColors: ({
            "up": Theme.success,
            "down": Theme.error,
            "flat": Theme.warning,
            "unknown": Theme.surfaceVariantText
        })

    // Shared state across all bar instances (multi-monitor safe)
    property var marketData: []
    property string lastError: ""

    readonly property var segments: Ticker.buildSegments(coins, marketData, changeColors)
    readonly property bool hasData: marketData && marketData.length > 0

    function syncGlobals() {
        marketData = PluginService.getGlobalVar("cryptoTicker", "marketData", []);
        lastError = PluginService.getGlobalVar("cryptoTicker", "lastError", "");
    }

    Connections {
        target: PluginService
        function onGlobalVarChanged(pluginId, varName) {
            if (pluginId === "cryptoTicker")
                root.syncGlobals();
        }
    }

    Component.onCompleted: {
        syncGlobals();
        requestFetch(false);
    }

    onCoinsChanged: requestFetch(true)
    onCurrencyChanged: requestFetch(true)

    function requestFetch(force) {
        if (!coins.length) {
            PluginService.setGlobalVar("cryptoTicker", "lastError", "No coins configured");
            return;
        }
        const now = Date.now();
        if (PluginService.getGlobalVar("cryptoTicker", "fetching", false))
            return;
        if (!force) {
            const lastTs = PluginService.getGlobalVar("cryptoTicker", "lastFetchTs", 0);
            const backoffUntil = PluginService.getGlobalVar("cryptoTicker", "backoffUntil", 0);
            if (now - lastTs < refreshInterval * 1000)
                return;
            if (now < backoffUntil)
                return;
        }
        PluginService.setGlobalVar("cryptoTicker", "fetching", true);
        Proc.runCommand("cryptoTicker.fetch", ["curl", "-sS", "--connect-timeout", "3", "--max-time", "8", "--compressed", "-w", "\n%{http_code}", Ticker.buildUrl(coins, currency)], (stdout, exitCode) => onFetchDone(stdout, exitCode), 100);
    }

    function onFetchDone(stdout, exitCode) {
        PluginService.setGlobalVar("cryptoTicker", "fetching", false);
        const res = Ticker.parseResponse(stdout, exitCode);
        if (res.ok) {
            PluginService.setGlobalVar("cryptoTicker", "marketData", res.data);
            PluginService.setGlobalVar("cryptoTicker", "lastFetchTs", Date.now());
            PluginService.setGlobalVar("cryptoTicker", "failCount", 0);
            PluginService.setGlobalVar("cryptoTicker", "lastError", "");
            return;
        }
        console.warn("CryptoTicker: " + res.error);
        if (res.status === 429) {
            const n = PluginService.getGlobalVar("cryptoTicker", "failCount", 0) + 1;
            PluginService.setGlobalVar("cryptoTicker", "failCount", n);
            const backoff = Math.min(Math.pow(2, n) * refreshInterval * 1000, 900000);
            PluginService.setGlobalVar("cryptoTicker", "backoffUntil", Date.now() + backoff);
        }
        // Keep marketData: last-known prices stay visible.
        PluginService.setGlobalVar("cryptoTicker", "lastError", res.error);
    }

    Timer {
        interval: root.refreshInterval * 1000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.requestFetch(false)
    }

    pillClickAction: () => root.requestFetch(true)

    horizontalBarPill: Component {
        Item {
            id: pill
            implicitWidth: root.tickerWidth
            implicitHeight: tickerRow.implicitHeight
            clip: true

            Row {
                id: tickerRow
                visible: root.hasData
                Repeater {
                    model: root.segments
                    Row {
                        StyledText {
                            text: modelData.symbol + ": "
                            color: modelData.symbolColor
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Bold
                        }
                        StyledText {
                            text: modelData.price
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                        }
                        StyledText {
                            visible: modelData.showChange
                            text: modelData.changeText
                            color: modelData.changeColor
                            font.pixelSize: Theme.fontSizeMedium
                        }
                        StyledText {
                            visible: modelData.separator
                            text: "   |   "
                            color: Theme.outline
                            font.pixelSize: Theme.fontSizeMedium
                        }
                    }
                }
                onImplicitWidthChanged: if (marquee.running)
                    marquee.restart()
            }

            StyledText {
                anchors.centerIn: parent
                visible: !root.hasData
                text: root.lastError ? "crypto: " + root.lastError : "crypto: …"
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
            }

            NumberAnimation {
                id: marquee
                target: tickerRow
                property: "x"
                from: pill.implicitWidth
                to: -tickerRow.implicitWidth
                duration: Math.max(1, (pill.implicitWidth + tickerRow.implicitWidth) / 60 * 1000)
                loops: Animation.Infinite
                running: root.marqueeEnabled && root.hasData && tickerRow.implicitWidth > pill.implicitWidth + 10
                onRunningChanged: if (!running)
                    tickerRow.x = 0
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS
            Repeater {
                model: root.segments
                Column {
                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: modelData.symbol
                        color: modelData.symbolColor
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Bold
                    }
                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: modelData.price
                        color: Theme.surfaceText
                        font.pixelSize: Theme.fontSizeSmall
                    }
                }
            }
            StyledText {
                visible: !root.hasData
                text: "…"
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
            }
        }
    }
}
```

- [ ] **Step 2: Verify plugin discovery**

Run: `dms ipc plugins list`
Expected: `cryptoTicker` listed (name "Crypto Ticker"). If absent, run `dms ipc plugins reload`, re-check, and validate `plugin.json` with `jq .`. (`dms plugins list` only shows registry-installed plugins — the IPC list reflects live PluginService discovery of the local dir.)

- [ ] **Step 3: Enable plugin**

Run: `dms ipc plugins enable cryptoTicker`
Expected: success response (not `ERROR`). Fallback: Settings (Ctrl+,) → Plugins → toggle on.

- [ ] **Step 4: Add to bar and verify render**

Settings → Widgets (DankBar layout) → add `cryptoTicker` to a section. Expected: pill appears; within ~10s shows `BTC: $… (+x.xx%) | ETH: … | USDT: …`; text scrolls if wider than 280px. If it shows `crypto: <error>`, check `qs` log / network.

- [ ] **Step 5: Commit**

```bash
git add CryptoTicker.qml
git -c user.email="dev@local" -c user.name="dev" commit -m "Add CryptoTicker bar widget"
```

---

### Task 3: `CryptoTickerSettings.qml`

**Files:**
- Create: `CryptoTickerSettings.qml`

**Interfaces:**
- Consumes: `PluginSettings`, `StringSetting`, `SliderSetting`, `ToggleSetting` (`qs.Modules.Plugins`).
- Produces: persisted keys `coins`, `currency`, `refreshInterval`, `tickerWidth`, `marqueeEnabled` under `pluginSettings.cryptoTicker` in `~/.config/DankMaterialShell/settings.json` — the exact keys Task 2 reads via `pluginData`.

- [ ] **Step 1: Write `CryptoTickerSettings.qml`**

```qml
import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "cryptoTicker"

    StringSetting {
        settingKey: "coins"
        label: "Coins"
        description: "CoinGecko coin IDs, comma separated (e.g. bitcoin,ethereum,solana)"
        placeholder: "bitcoin,ethereum,tether"
        defaultValue: "bitcoin,ethereum,tether"
    }

    StringSetting {
        settingKey: "currency"
        label: "Fiat currency"
        description: "CoinGecko vs_currency (usd, eur, vnd, jpy…). Note: prices always display with a $ prefix."
        placeholder: "usd"
        defaultValue: "usd"
    }

    SliderSetting {
        settingKey: "refreshInterval"
        label: "Refresh interval"
        description: "Seconds between price updates. CoinGecko free tier rate-limits aggressive polling."
        defaultValue: 300
        minimum: 30
        maximum: 3600
        unit: "s"
    }

    SliderSetting {
        settingKey: "tickerWidth"
        label: "Ticker width"
        description: "Visible width of the scrolling ticker in the bar"
        defaultValue: 280
        minimum: 120
        maximum: 600
        unit: "px"
    }

    ToggleSetting {
        settingKey: "marqueeEnabled"
        label: "Scrolling marquee"
        description: "Scroll prices when they exceed the ticker width"
        defaultValue: true
    }
}
```

- [ ] **Step 2: Verify settings UI and persistence**

Settings → Plugins → Crypto Ticker → change `refreshInterval` to 60. Then:
Run: `jq '.pluginSettings.cryptoTicker' ~/.config/DankMaterialShell/settings.json`
Expected: `"refreshInterval": 60` present. Widget picks up new interval on next tick (no restart needed).

- [ ] **Step 3: Commit**

```bash
git add CryptoTickerSettings.qml
git -c user.email="dev@local" -c user.name="dev" commit -m "Add plugin settings UI"
```

---

### Task 4: Live validation + README

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Failure-path verification (non-invasive)**

In plugin settings set `currency` to `zzz` (invalid) → next tick: CoinGecko returns non-200 → pill keeps last-known prices (or shows `crypto: HTTP 4xx` if no data yet). Restore `usd` → next tick recovers. Also set `coins` to `bogus-coin-id` → that coin renders `unknown` price without crashing.

- [ ] **Step 2: Dedup check (if multi-monitor)**

With the widget on 2+ bars/screens: `journalctl --user -f` or `qs` log — only one `curl` per interval (Proc debounce + `fetching` gate). Single-monitor: skip, note in README.

- [ ] **Step 3: Write `README.md`**

Cover: overview; features (marquee, per-coin colors, 24h change, click-to-refresh); requirements (DMS ≥1.4.0, curl); install (already in `~/.config/DankMaterialShell/plugins/CryptoTicker/`; `dms plugins list`; Settings → Plugins → enable); adding to bar (Settings → Widgets → add `cryptoTicker` to a section); settings table (keys, defaults, ranges); debugging (`dms ipc plugins status`, `dms ipc plugins reload`, `qs -v` logs, `jq '.pluginSettings.cryptoTicker' ~/.config/DankMaterialShell/settings.json`); known limitations (no popout, `$` hardcoded, marquee horizontal-only, CoinGecko free-tier rate limits, `panel-position` superseded by DankBar layout, original GNOME extension untouched at `~/.local/share/gnome-shell/extensions/crypto-ticker@ntxinh/`).

- [ ] **Step 4: Final sweep + commit**

```bash
node --test tests/
dms ipc plugins list
git add README.md
git -c user.email="dev@local" -c user.name="dev" commit -m "Add README and finalize plugin"
```
Expected: tests pass, plugin listed, working tree clean.
