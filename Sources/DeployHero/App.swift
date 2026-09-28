// DeployHero: a deployment status light for the macOS menu bar, across
// Vercel, Railway, Laravel Cloud and Fly.io.
//
// Monitor owns the state (tokens, polling, the light, notifications);
// StatusItem draws the dot and its menu; SettingsView is the connect /
// settings window. Each platform lives in Providers/ and hands back the
// latest deployment per project in one shared shape.

import AppKit
import SwiftUI
import UserNotifications

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let monitor = Monitor()
    private var statusItem: StatusItem?
    private var window: NSWindow?

    /// Notifications need a bundle; `swift run` has none.
    private var notifications: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = StatusItem(monitor: monitor, openSettings: showSettings, openAbout: showAbout)
        monitor.onSignedOut = { [weak self] in self?.showSettings() }
        monitor.notify = { [weak self] title, body, url in self?.post(title, body, url) }

        if let center = notifications {
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [monitor] _ in
            Task { @MainActor in await monitor.refresh() }
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [monitor] _ in
            Task { @MainActor in monitor.pause() }
        }

        if monitor.connected.isEmpty {
            showSettings()
        } else {
            Task { await monitor.refresh() }
        }
    }

    /// Opening the app again (Finder, Spotlight) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: - Windows

    func showSettings() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.title = "DeployHero"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(monitor: monitor, openAbout: showAbout))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func showAbout() {
        let credits = NSMutableAttributedString(
            string: "A menu bar traffic light for your deployments on Vercel, Railway, Laravel Cloud and Fly.io.\n\nMade by ",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(string: "dondo.dev", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .link: URL(string: "https://dondo.dev")!,
        ]))
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        credits.addAttribute(.paragraphStyle, value: center, range: NSRange(location: 0, length: credits.length))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // MARK: - Notifications

    private func post(_ title: String, _ body: String, _ url: URL?) {
        guard let center = notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let url { content.userInfo = ["url": url.absoluteString] }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Show banners even while the settings window is in front.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Clicking a notification opens that deployment.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        if let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }
}
