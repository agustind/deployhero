// The connect / settings window.

import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var monitor: Monitor
    var openAbout: () -> Void

    private var signedIn: Bool { !monitor.connected.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(ProviderID.allCases, id: \.self) { id in
                        PlatformRow(monitor: monitor, id: id)
                    }
                } header: {
                    Text("Platforms")
                } footer: {
                    if !signedIn {
                        Text("Connect a platform with an access token. Tokens are stored in your macOS Keychain and only sent to that platform's API.")
                            .foregroundStyle(.secondary)
                    }
                }

                if signedIn {
                    Section {
                        Toggle("Production deployments only", isOn: Binding(
                            get: { monitor.settings.productionOnly },
                            set: { on in Task { await monitor.setProductionOnly(on) } }))
                    }
                    ProjectsSection(monitor: monitor)
                }

                LoginItemSection()
            }
            .formStyle(.grouped)

            HStack(spacing: 4) {
                Text("v" + appVersion)
                Text("·")
                Button("About", action: openAbout).buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 12)
        }
        .frame(minWidth: 420, minHeight: 480)
    }
}

// MARK: - Platforms

private struct PlatformRow: View {
    @Bindable var monitor: Monitor
    let id: ProviderID

    @State private var open = false
    @State private var token = ""
    @State private var busy = false
    @State private var connectError: String?
    @State private var confirmDisconnect = false
    @FocusState private var tokenFocused: Bool

    var body: some View {
        let p = id.provider
        let conn = monitor.conns[id]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Badge(id: id).opacity(conn == nil ? 0.45 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).fontWeight(.semibold)
                    Text(accountLine(conn))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                if conn != nil {
                    Button("Disconnect") { confirmDisconnect = true }
                } else {
                    Button(open ? "Cancel" : "Connect") {
                        open.toggle()
                        connectError = nil
                        tokenFocused = open
                    }
                }
            }

            if let conn, let label = p.scopeLabel, let scopes = conn.account?.scopes, scopes.count >= 2 {
                Picker(label, selection: Binding(
                    get: { monitor.scope(of: id) },
                    set: { s in Task { await monitor.setScope(s, for: id) } })) {
                    ForEach(scopes, id: \.id) { Text($0.name).tag($0.id) }
                }
            }

            if conn == nil && open {
                Text(helpText(p))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    SecureField("\(p.name) access token", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .focused($tokenFocused)
                        .onSubmit(connect)
                    Button("Connect", action: connect).disabled(busy)
                }
            }

            if let err = conn?.error ?? (conn == nil ? connectError : nil) {
                Text(err).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog("Disconnect \(p.name)?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { monitor.disconnect(id) }
        } message: {
            Text("The token is removed from your Keychain.")
        }
    }

    private func accountLine(_ conn: Monitor.Connection?) -> String {
        guard let conn else { return "Not connected" }
        let parts = [conn.account?.name, conn.account?.detail].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Connected" : parts.joined(separator: " · ")
    }

    private func helpText(_ p: any Provider) -> AttributedString {
        let md = "[Create a \(p.name) token](\(p.tokenURL.absoluteString)). \(p.tokenHelp) It's only sent to `\(p.host)`."
        return (try? AttributedString(markdown: md)) ?? AttributedString(md)
    }

    private func connect() {
        guard !busy else { return }
        busy = true
        connectError = nil
        Task {
            defer { busy = false }
            do {
                try await monitor.connect(id, token: token)
                token = ""
                open = false
            } catch {
                connectError = error.localizedDescription
            }
        }
    }
}

struct Badge: View {
    let id: ProviderID
    var small = false

    var body: some View {
        let (letter, bg, fg): (String, Color, Color) = switch id {
        case .vercel: ("▲", .primary, Color(nsColor: .textBackgroundColor))
        case .railway: ("R", Color(red: 0.17, green: 0.17, blue: 0.2), .white)
        case .laravel: ("L", Color(red: 0.96, green: 0.19, blue: 0.01), .white)
        case .fly: ("F", Color(red: 0.49, green: 0.23, blue: 0.93), .white)
        }
        Text(letter)
            .font(.system(size: small ? 9 : 12, weight: .bold))
            .foregroundStyle(fg)
            .frame(width: small ? 16 : 24, height: small ? 16 : 24)
            .background(bg, in: RoundedRectangle(cornerRadius: small ? 4 : 6))
            .help(id.provider.name)
    }
}

// MARK: - Projects

private struct ProjectsSection: View {
    @Bindable var monitor: Monitor

    var body: some View {
        Section {
            if monitor.projects.isEmpty {
                Text("No deployments yet.").foregroundStyle(.secondary)
            }
            ForEach(monitor.projects, id: \.uniqueID) { p in
                ProjectRow(monitor: monitor, p: p)
            }
        } header: {
            HStack {
                Text("Latest per project")
                Spacer()
                Button("Refresh") { Task { await monitor.refresh() } }
                    .buttonStyle(.link).font(.caption)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("Light follows **\(monitor.settings.watch == nil ? "all projects" : monitor.followsLabel)**. Tick projects to choose which ones it tracks.")
                    if monitor.settings.watch != nil {
                        Button("Follow all") { monitor.toggleWatch(nil) }.buttonStyle(.link)
                    }
                }
                if let checked = monitor.lastChecked {
                    Text("Checked \(checked.formatted(date: .omitted, time: .standard))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct ProjectRow: View {
    var monitor: Monitor
    let p: Deployment

    var body: some View {
        let watched = monitor.isWatched(p.watchKey)
        HStack(spacing: 10) {
            // With "all" followed every box is unticked; ticking narrows from there.
            Toggle("Include in the menu bar light", isOn: Binding(
                get: { watched && monitor.settings.watch != nil },
                set: { _ in monitor.toggleWatch(p.watchKey) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Include in the menu bar light")
            Group {
                Circle().fill(p.state.color).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(p.project).fontWeight(.semibold).lineLimit(1)
                        if !p.target.isEmpty {
                            Text(p.target)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                        }
                    }
                    Text(p.message ?? p.status)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .opacity(watched ? 1 : 0.45)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                Badge(id: p.provider, small: true)
                // Keep the "5m ago" labels honest between polls.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(ago(p.created, now: context.date)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let url = p.url { NSWorkspace.shared.open(url) } }
    }
}

extension DeployState {
    var color: Color {
        switch self {
        case .ready: .green
        case .error: .red
        case .building: .yellow
        }
    }
}

// MARK: - Start at login

private struct LoginItemSection: View {
    @State private var status = SMAppService.mainApp.status

    var body: some View {
        // Only a bundled .app can register itself (not `swift run`).
        if Bundle.main.bundleURL.pathExtension == "app" {
            Section {
                Toggle(isOn: Binding(
                    get: { status == .enabled || status == .requiresApproval },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {}
                        status = SMAppService.mainApp.status
                    })) {
                    Text("Start at login")
                    if status == .requiresApproval {
                        Text("Allow it in System Settings → General → Login Items")
                    }
                }
            }
        }
    }
}

var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}
