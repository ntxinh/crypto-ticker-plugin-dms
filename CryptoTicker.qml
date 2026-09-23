import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "CryptoTicker.js" as Ticker

PluginComponent {
    id: root

    // Settings (pluginData auto-reloads on pluginDataChanged)
    property string coinsCsv: pluginData.coins || "bitcoin,ethereum,tether"
    property var coins: Ticker.parseCoins(coinsCsv)
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

    onCoinsCsvChanged: requestFetch(true)
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
            implicitHeight: Math.max(tickerRow.implicitHeight, statusText.implicitHeight)
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
                id: statusText
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
                visible: root.hasData
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
