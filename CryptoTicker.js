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
        return "$" + truncated.toFixed(2);
    }
    var digits = String(Math.floor(p));
    var grouped = "";
    while (digits.length > 3) {
        grouped = "," + digits.substring(digits.length - 3) + grouped;
        digits = digits.substring(0, digits.length - 3);
    }
    return "$" + digits + grouped;
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
