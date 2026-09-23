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
