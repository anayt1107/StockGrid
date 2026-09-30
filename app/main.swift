// StockGrid desktop app: a native window around index.html.
// Pages load from stockgrid://app/, and stockgrid://app/api/chart is answered natively
// by fetching Yahoo Finance, so no local server is needed.
import Cocoa
import WebKit

let scheme = "stockgrid"
let ranges: [String: String] = [
    "1d": "5m", "5d": "15m", "1mo": "1d", "6mo": "1d", "ytd": "1d", "1y": "1d", "2y": "1d", "5y": "1wk",
]
let symbolPattern = try! NSRegularExpression(pattern: "^[A-Z0-9.\\-^=]{1,15}$")

final class SchemeHandler: NSObject, WKURLSchemeHandler {
    private var active = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        active.insert(id)
        guard let url = task.request.url else { return finish(task, 400, Data()) }

        if url.path == "/api/chart" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let symbol = (items.first { $0.name == "symbol" }?.value ?? "").uppercased()
            let range = items.first { $0.name == "range" }?.value ?? "6mo"
            let ns = symbol as NSString
            guard symbolPattern.firstMatch(in: symbol, range: NSRange(location: 0, length: ns.length)) != nil,
                  let interval = ranges[range] else {
                return finish(task, 400, json(["error": "Invalid symbol or range"]))
            }
            var comps = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/")!
            comps.path += symbol
            comps.queryItems = [
                .init(name: "range", value: range), .init(name: "interval", value: interval),
                .init(name: "includePrePost", value: "false"),
            ]
            var req = URLRequest(url: comps.url!, timeoutInterval: 15)
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { data, resp, err in
                DispatchQueue.main.async {
                    guard self.active.contains(id) else { return }
                    if let err = err {
                        return self.finish(task, 502, self.json(["error": "Could not reach the data provider: \(err.localizedDescription)"]))
                    }
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 502
                    self.finish(task, status == 200 ? 200 : 404, data ?? Data())
                }
            }.resume()
            return
        }

        let name = url.path == "/" || url.path.isEmpty ? "index.html" : String(url.path.dropFirst())
        guard name == "index.html",
              let file = Bundle.main.url(forResource: "index", withExtension: "html"),
              let data = try? Data(contentsOf: file) else {
            return finish(task, 404, Data("Not found".utf8), type: "text/plain")
        }
        finish(task, 200, data, type: "text/html; charset=utf-8")
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }

    private func json(_ obj: [String: String]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    private func finish(_ task: WKURLSchemeTask, _ status: Int, _ body: Data, type: String = "application/json") {
        let id = ObjectIdentifier(task)
        guard active.contains(id), let url = task.request.url else { return }
        active.remove(id)
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": type, "Cache-Control": "no-store"])!
        task.didReceive(resp)
        task.didReceive(body)
        task.didFinish()
    }
}

// Saves the page's state (watchlist, trades, orders) to ~/Library/Application Support/StockGrid/state.json.
final class StateStore: NSObject, WKScriptMessageHandler {
    let url: URL
    private(set) var state: [String: String] = [:]

    override init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StockGrid", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("state.json")
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            state = obj
        }
    }

    var bootstrapScript: String {
        let data = (try? JSONSerialization.data(withJSONObject: state)) ?? Data("{}".utf8)
        return "window.__stockgridState = \(String(data: data, encoding: .utf8) ?? "{}");"
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let key = body["k"] as? String else { return }
        state[key] = body["v"] as? String
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// Shared sync through a folder (normally a shared iCloud Drive folder). Each Mac writes only its own
// stockgrid-<device>.json there and reads everyone else's; the page merges them item by item.
final class SyncManager: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    private(set) var folder: URL?
    private var seen: [String: Date] = [:]
    private var timer: Timer?
    private let prefix = "stockgrid-"
    private let folderKey = "syncFolder"

    override init() {
        super.init()
        if let path = ProcessInfo.processInfo.environment["STOCKGRID_SYNC_DIR"] ?? UserDefaults.standard.string(forKey: folderKey) {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    // Called on every page load: resend status and every file.
    func pageLoaded() {
        seen = [:]
        sendStatus()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "write":
            guard let folder, let name = body["name"] as? String, let text = body["text"] as? String,
                  name.hasPrefix(prefix), name.hasSuffix(".json"), !name.contains("/") else { return }
            let url = folder.appendingPathComponent(name)
            var coordErr: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordErr) { u in
                do { try Data(text.utf8).write(to: u, options: .atomic) }
                catch { self.sendStatus(error: "Couldn't save to the sync folder: \(error.localizedDescription)") }
            }
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate { seen[name] = date }
        case "choose":
            choose()
        case "stop":
            folder = nil
            UserDefaults.standard.removeObject(forKey: folderKey)
            seen = [:]
            sendStatus()
        case "reveal":
            if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        default: break
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Sync Here"
        panel.message = "Choose the shared iCloud Drive folder everyone uses for StockGrid."
        panel.directoryURL = folder ?? SyncManager.iCloudDrive
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        UserDefaults.standard.set(url.path, forKey: folderKey)
        seen = [:]
        sendStatus()
        poll()
    }

    private func poll() {
        guard let folder, let webView else { return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return sendStatus(error: "Can't open the sync folder. It may have been moved, or iCloud hasn't finished downloading it.")
        }
        var changed: [[String: Any]] = []
        for url in items {
            let name = url.lastPathComponent
            // Files iCloud hasn't downloaded yet appear as ".stockgrid-x.json.icloud" placeholders.
            if name.hasPrefix("." + prefix), name.hasSuffix(".icloud") {
                let real = folder.appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count)))
                try? fm.startDownloadingUbiquitousItem(at: real)
                continue
            }
            guard name.hasPrefix(prefix), name.hasSuffix(".json") else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if seen[name] == date { continue }
            var text: String?
            var coordErr: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordErr) { u in
                text = try? String(contentsOf: u, encoding: .utf8)
            }
            guard let text else { continue }
            seen[name] = date
            changed.append(["name": name, "text": text])
        }
        guard !changed.isEmpty, let data = try? JSONSerialization.data(withJSONObject: changed),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.stockgridSyncReceive && window.stockgridSyncReceive(\(json))")
    }

    private func sendStatus(error: String? = nil) {
        var status: [String: Any] = ["deviceName": Host.current().localizedName ?? "Mac"]
        if let folder {
            status["folder"] = folder.path
            status["inICloud"] = folder.path.hasPrefix(SyncManager.iCloudDrive.path)
        }
        if let error { status["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: status),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.stockgridSyncStatus && window.stockgridSyncStatus(\(json))")
    }
}

// Auto-updates from the public GitHub repo's latest release.
final class Updater {
    let repo = Bundle.main.object(forInfoDictionaryKey: "StockGridUpdateRepo") as? String ?? ""
    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    private var busy = false
    private let skipKey = "skippedVersion"

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func check(userInitiated: Bool) {
        guard !busy else { return }
        guard !repo.isEmpty, let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            if userInitiated { alert("Updates aren't set up", "This copy of StockGrid was built without a GitHub repo to update from.") }
            return
        }
        busy = true
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("StockGrid/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                self.busy = false
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = obj["tag_name"] as? String else {
                    if userInitiated {
                        self.alert("Couldn't check for updates", err?.localizedDescription ?? "GitHub didn't return a release for \(self.repo).")
                    }
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                guard Updater.isNewer(latest, than: self.current) else {
                    if userInitiated { self.alert("StockGrid is up to date", "You have version \(self.current), the latest release.") }
                    return
                }
                if !userInitiated && UserDefaults.standard.string(forKey: self.skipKey) == latest { return }
                let assets = obj["assets"] as? [[String: Any]] ?? []
                guard let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true })?["browser_download_url"] as? String,
                      let zipURL = URL(string: zip) else {
                    if userInitiated { self.alert("Update not ready", "Version \(latest) is published but its download isn't attached yet. Try again in a few minutes.") }
                    return
                }
                self.offer(version: latest, notes: obj["body"] as? String ?? "", zip: zipURL)
            }
        }.resume()
    }

    private func offer(version: String, notes: String, zip: URL) {
        let a = NSAlert()
        a.messageText = "StockGrid \(version) is available"
        a.informativeText = "You have version \(current). Your watchlist, trades and sync settings are kept.\n\n" + String(notes.prefix(600))
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Later")
        a.addButton(withTitle: "Skip This Version")
        switch a.runModal() {
        case .alertFirstButtonReturn: install(zip)
        case .alertThirdButtonReturn: UserDefaults.standard.set(version, forKey: skipKey)
        default: break
        }
    }

    private func install(_ zip: URL) {
        busy = true
        NSApp.mainWindow?.title = "StockGrid — downloading update…"
        URLSession.shared.downloadTask(with: zip) { file, resp, err in
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("stockgrid-update-\(UUID().uuidString)")
            try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            var newApp: URL?
            if let file, (resp as? HTTPURLResponse)?.statusCode == 200 {
                let local = tmp.appendingPathComponent("StockGrid.zip")
                try? fm.moveItem(at: file, to: local)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", local.path, tmp.path]
                try? unzip.run(); unzip.waitUntilExit()
                let candidate = tmp.appendingPathComponent("StockGrid.app")
                if unzip.terminationStatus == 0, fm.fileExists(atPath: candidate.path) { newApp = candidate }
            }
            DispatchQueue.main.async {
                self.busy = false
                NSApp.mainWindow?.title = "StockGrid"
                guard let newApp else {
                    return self.alert("Update failed", "Couldn't download the update. \(err?.localizedDescription ?? "")")
                }
                let dest = Bundle.main.bundleURL
                guard fm.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
                    return self.alert("Update needs permission", "StockGrid can't replace itself in \(dest.deletingLastPathComponent().path). Move StockGrid to your Applications folder and try again.")
                }
                // Swap the app bundle after this process exits, then relaunch it.
                let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                let script = """
                while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
                rm -rf \(q(dest.path + ".old")); mv \(q(dest.path)) \(q(dest.path + ".old")) && mv \(q(newApp.path)) \(q(dest.path)) && rm -rf \(q(dest.path + ".old"))
                xattr -dr com.apple.quarantine \(q(dest.path)) 2>/dev/null
                open \(q(dest.path))
                """
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", script]
                try? p.run()
                NSApp.terminate(nil)
            }
        }.resume()
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    let handler = SchemeHandler()
    let stateStore = StateStore()
    let sync = SyncManager()
    let updater = Updater()

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: scheme)
        config.websiteDataStore = .default()
        config.userContentController.addUserScript(
            WKUserScript(source: stateStore.bootstrapScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(stateStore, name: "store")
        config.userContentController.add(sync, name: "sync")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true
        webView.setValue(false, forKey: "drawsBackground")
        sync.webView = webView

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "StockGrid"
        window.minSize = NSSize(width: 480, height: 400)
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("StockGridMain")
        window.makeKeyAndOrderFront(nil)
        webView.load(URLRequest(url: URL(string: "\(scheme)://app/index.html")!))
        NSApp.activate(ignoringOtherApps: true)
        if ProcessInfo.processInfo.environment["STOCKGRID_SELFTEST"] != nil { selfTest(); return }
        // Check for updates shortly after launch, then every 6 hours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.updater.check(userInitiated: false) }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.updater.check(userInitiated: false) }
    }

    @objc func checkForUpdates(_ sender: Any?) { updater.check(userInitiated: true) }

    // STOCKGRID_SELFTEST=1 StockGrid.app/Contents/MacOS/StockGrid → prints what loaded, then quits.
    private func selfTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            let js = """
            JSON.stringify({cards: document.querySelectorAll('.card').length,
              failed: [...document.querySelectorAll('.card.err')].map(e => e.dataset.sym + ': ' + e.textContent.trim().slice(0, 80)),
              charts: document.querySelectorAll('.card .plot svg').length,
              signals: document.querySelectorAll('.card .pill').length,
              tape: document.getElementById('tape').textContent, nativeKeys: nativeStore ? Object.keys(nativeStore) : null,
              sync: typeof syncStatus === 'undefined' ? null : {folder: syncStatus.folder, error: syncStatus.error || null, peers: Object.keys(remoteDocs).length,
                symbols: symbols.length, lots: lots.length, orders: orders.length}})
            """
            self.webView.evaluateJavaScript(js) { result, error in
                print(result ?? "error: \(String(describing: error))")
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { sync.pageLoaded() }

    // Keep the app on its own page; open outside links (e.g. TradingView) in the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        if url.scheme == scheme || !isMainFrame || url.scheme == "about" {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    @objc func refreshData(_ sender: Any?) {
        webView.evaluateJavaScript("window.stockgridRefresh && window.stockgridRefresh()")
    }
    @objc func reloadPage(_ sender: Any?) {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: stateStore.bootstrapScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView.reload()
    }
    @objc func showShortcuts(_ sender: Any?) {
        webView.evaluateJavaScript("document.getElementById('keys').showModal()")
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "About StockGrid", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide StockGrid", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(.separator())
        app.addItem(withTitle: "Quit StockGrid", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Refresh Prices", action: #selector(refreshData(_:)), keyEquivalent: "r")
        let reload = view.addItem(withTitle: "Reload App", action: #selector(reloadPage(_:)), keyEquivalent: "r")
        reload.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(.separator())
        view.addItem(withTitle: "Keyboard Shortcuts", action: #selector(showShortcuts(_:)), keyEquivalent: "/")
        view.addItem(.separator())
        let fs = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = view

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winItem.submenu = win
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
