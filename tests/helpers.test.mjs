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
