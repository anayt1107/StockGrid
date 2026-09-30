# StockGrid

A Mac app for watching a grid of stock charts. Paste tickers in any format and each one becomes a chart card with a technical signal (Buy / Hold / Sell / Short), a volatility rating, and an expandable view with indicators and TradingView charts. A **Bought** section tracks your trades (market and limit orders, longs and shorts) with gain and loss stats. Everything can be shared with other people through an iCloud Drive folder.

> Tracking only. StockGrid never places real orders, and its signals are mechanical readings of technical indicators, not financial advice.

## Install

Run this in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/anayt1107/StockGrid/main/install.sh | bash
```

It downloads the latest release into `/Applications` and opens it. Run it again any time to reinstall.

To install by hand instead, download `StockGrid-x.y.z.zip` from the [Releases](https://github.com/anayt1107/StockGrid/releases/latest) page, unzip it, and drag **StockGrid** to Applications. The app isn't notarized by Apple, so the first time you open it, right-click it and choose **Open**.

The first time StockGrid opens on a Mac, it asks for the group's Stock Market Game username and password. After that it stays unlocked on that Mac. The login is checked inside the app, so treat it as a simple lock rather than real security.

## Updates

StockGrid checks for a new release shortly after it opens and every 6 hours. When one is available it asks **Install and Relaunch**, then downloads the new version, replaces itself and reopens. You can also check yourself with **StockGrid › Check for Updates…**. Your watchlist, trades and sync settings are kept across updates.

## Sharing a watchlist and trades with others

1. In Finder, open **iCloud Drive** and make a folder, for example `StockGrid Shared`.
2. Right-click it, choose **Share › Share Folder**, invite everyone, and set permission to **Can make changes**.
3. Each person opens StockGrid, clicks **Sync** at the top, then **Choose shared folder…** and picks that folder.

Each Mac writes only its own file in the folder, and every app merges everyone's changes item by item (newest change wins, deletions included), so edits made at the same time don't overwrite each other. Changes appear as fast as iCloud syncs the folder, usually within seconds.

## Using it

| Key | Action |
| --- | --- |
| `1`–`7` | Timeframe: 1D, 5D, 1M, 6M, YTD, 1Y, 5Y |
| `[` `]` | Previous / next timeframe |
| `J` `K` or `←` `→` | Next / previous stock when one is expanded |
| `Enter` / `Esc` | Expand / collapse the focused card |
| `T` | Overview or TradingView tab |
| `W` / `B` | Watchlist / Bought |
| `N` | New trade |
| `S` | Cycle sort |
| `R` | Refresh prices |
| `/` | Jump to the paste box |
| `?` | Show all shortcuts |

Your data lives in `~/Library/Application Support/StockGrid/state.json`.

## Development

- `index.html` is the whole interface (one file, no build step).
- `app/main.swift` is the native wrapper: window, price fetching, saving, iCloud folder sync and the updater.
- `./build.sh` builds `StockGrid.app` (needs Xcode or the Command Line Tools).
- `python3 server.py` serves the page at <http://localhost:8765> for working on it in a browser. Sync and updates only work in the app.

### Publishing a release

```bash
./release.sh 1.2.0 "What changed in this version"
```

This bumps `VERSION`, commits, tags `v1.2.0` and pushes. GitHub Actions builds the app and publishes the release, and every installed copy offers the update.
