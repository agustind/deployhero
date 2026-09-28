// The menu bar dot and its menu. The menu is rebuilt each time it opens, so
// "5m ago" labels are always current.

import AppKit
import Observation

@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let monitor: Monitor
    private let openSettings: () -> Void
    private let openAbout: () -> Void

    init(monitor: Monitor, openSettings: @escaping () -> Void, openAbout: @escaping () -> Void) {
        self.monitor = monitor
        self.openSettings = openSettings
        self.openAbout = openAbout
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        observe()
    }

    /// Redraw the dot and tooltip whenever what they read changes.
    private func observe() {
        withObservationTracking {
            let light = monitor.light
            let tip = monitor.connected.isEmpty ? "no platforms connected" : monitor.summary
            item.button?.image = Self.dot(light)
            item.button?.toolTip = "DeployHero: " + tip
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    // MARK: - Icon

    private static func dot(_ light: Light) -> NSImage {
        let color: NSColor = switch light {
        case .green: .systemGreen
        case .yellow: .systemYellow
        case .red: .systemRed
        case .gray: .systemGray
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
            color.setFill()
            circle.fill()
            color.shadow(withLevel: 0.25)?.setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
            return true
        }
        image.isTemplate = false   // keep the red/yellow/green instead of a mono silhouette
        return image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in build() { menu.addItem(item) }
    }

    private func build() -> [NSMenuItem] {
        let m = monitor
        var menu: [NSMenuItem] = []
        let ids = m.connected
        if ids.isEmpty {
            menu.append(.label("No platforms connected"))
            menu.append(.action("Connect a Platform…", do: openSettings))
        } else {
            let errs = m.errors
            menu.append(.label(errs.count == ids.count ? "⚠️ Can’t check deployments" : m.summary))
            for (id, msg) in errs {
                menu.append(.label("⚠️ \(id.provider.name): \(msg.prefix(60))"))
            }
            // One platform: a flat list. Several: grouped under headers.
            let now = Date()
            for id in ids {
                let list = m.projects.filter { $0.provider == id }.prefix(ids.count > 1 ? 10 : 15)
                let scope = m.scopeName(id)
                menu.append(.separator())
                menu.append(.label(ids.count > 1
                    ? id.provider.name + (scope.isEmpty ? "" : " · " + scope)
                    : "Scope: " + scope))
                for p in list {
                    let url = p.url
                    menu.append(.action("\(Self.emoji(p.state))  \(p.displayName) — \(ago(p.created, now: now))") {
                        if let url { NSWorkspace.shared.open(url) }
                    })
                }
            }
            menu.append(.separator())
            if !m.projects.isEmpty {
                let follows = NSMenuItem(title: "Light follows: " + m.followsLabel, action: nil, keyEquivalent: "")
                follows.submenu = followsMenu()
                menu.append(follows)
                menu.append(.separator())
            }
            menu.append(.action("Refresh Now", key: "r") { Task { await m.refresh() } })
            if ids.count == 1 {
                let id = ids[0]
                menu.append(.action("Open \(id.provider.name) Dashboard") { NSWorkspace.shared.open(m.dashboardURL(id)) })
            } else {
                let dashboards = NSMenuItem(title: "Open Dashboard", action: nil, keyEquivalent: "")
                dashboards.submenu = NSMenu()
                for id in ids {
                    dashboards.submenu?.addItem(.action(id.provider.name) { NSWorkspace.shared.open(m.dashboardURL(id)) })
                }
                menu.append(dashboards)
            }
            menu.append(.action("Settings…", key: ",", do: openSettings))
        }
        menu.append(.separator())
        menu.append(.action("About DeployHero", do: openAbout))
        menu.append(.action("Quit", key: "q") { NSApp.terminate(nil) })
        return menu
    }

    private func followsMenu() -> NSMenu {
        let m = monitor
        let ids = m.connected
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.action("All projects", checked: m.settings.watch == nil) { m.toggleWatch(nil) })
        for id in ids {
            let list = m.projects.filter { $0.provider == id }.prefix(30)
            if list.isEmpty { continue }
            menu.addItem(.separator())
            if ids.count > 1 { menu.addItem(.label(id.provider.name)) }
            for p in list {
                let key = p.watchKey
                menu.addItem(.action(p.displayName, checked: m.settings.watch?.contains(key) ?? false) { m.toggleWatch(key) })
            }
        }
        return menu
    }

    private static func emoji(_ state: DeployState) -> String {
        switch state {
        case .ready: "🟢"
        case .error: "🔴"
        case .building: "🟡"
        }
    }
}

/// A menu item that runs a closure.
private final class ClosureItem: NSMenuItem {
    private var handler: () -> Void = {}

    convenience init(_ title: String, key: String, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(run), keyEquivalent: key)
        self.handler = handler
        target = self
    }

    @objc private func run() { handler() }
}

private extension NSMenuItem {
    static func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    static func action(_ title: String, key: String = "", checked: Bool = false, do handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureItem(title, key: key, handler: handler)
        item.state = checked ? .on : .off
        return item
    }
}
