# DeployHero

A tiny native macOS menu bar app, written in Swift with AppKit and SwiftUI, that shows the status
of your deployments on **Vercel**, **Railway**, **Laravel Cloud** and **Fly.io** as one traffic
light.

| Light | Meaning |
| ----- | ------- |
| 🟢 | The latest deployment of every followed project is ready |
| 🟡 | A deployment is building or queued |
| 🔴 | A followed project's latest deployment failed |
| ⚪️ | Nothing connected, no deployments, or no platform can be reached |

## Features

- **Several platforms, one light.** Connect any mix of Vercel, Railway, Laravel Cloud and Fly.io.
  The menu groups projects by platform.
- **Per-project menu.** Click the dot to see each project's latest deployment and how long ago it
  ran. Click a project to open it.
- **Choose what the light follows.** Pick all projects, one project, or any mix across
  platforms, either from **Light follows ▸** in the menu or with the checkboxes in the settings
  window.
- **Scopes.** Pick a Vercel team, a Railway workspace or a Fly.io organization. A Laravel Cloud
  token already belongs to one organization.
- **Production only.** Optionally ignore preview deployments and non-production environments.
- **Notifications.** Get a macOS notification when a deployment finishes or fails, including
  quick deploys that start and finish between two checks.
- **Adaptive polling.** Checks every 10s while something is building and every 60s otherwise,
  and refreshes after the Mac wakes from sleep.
- **Start at login.** Optionally launch the app when you log in.

## Install

1. Download the latest `.dmg` from [Releases](https://github.com/agustind/deployhero/releases/latest).
2. Open it and drag **DeployHero** into **Applications**.
3. Launch it. A dot appears in the menu bar, and the settings window opens so you can connect a
   platform.

The app is signed with a Developer ID and notarized by Apple, so it opens without Gatekeeper
warnings. It requires macOS 14 or newer on an Apple Silicon Mac.

## Connecting platforms

Open **Settings…** and click **Connect** next to a platform, then paste a token. Each token is
stored in the **macOS Keychain**, never written to disk in plain text, and is only sent to that
platform's API. **Disconnect** removes it from the Keychain.

| Platform | Token | Sent to |
| -------- | ----- | ------- |
| Vercel | A personal access token from <https://vercel.com/account/tokens>. Scoping it to the team you want to watch is enough. | `api.vercel.com` |
| Railway | An **account** token from <https://railway.com/account/tokens>, created with no workspace selected. Workspace and project tokens can't list workspaces. | `backboard.railway.com` |
| Laravel Cloud | An API token: navigate to your Laravel Cloud organization settings, click on the **API tokens** section in the sidebar, then click the **Create API Token** button. Read access to applications, environments and deployments is enough. | `cloud.laravel.com` |
| Fly.io | A personal access token (<https://fly.io/user/personal_access_tokens>) or an org token (`fly tokens create org`). | `api.fly.io` |

## What counts as a "project"

Each platform models deployments a little differently. The app shows the newest deployment of
each of these:

| Platform | One entry per | Status source | "Production only" keeps |
| -------- | ------------- | ------------- | ----------------------- |
| Vercel | project | the 100 most recent deployments in the team (`GET /v6/deployments`) | `target: production` |
| Railway | service × environment | recent deployments of up to 30 projects in the workspace (GraphQL) | the `production` environment |
| Laravel Cloud | application × environment | `GET /environments/{id}/deployments` for each environment | the application's default environment, or one named `production` |
| Fly.io | app | the app's latest release (GraphQL) | everything (Fly has no previews) |

Every platform's statuses map onto three states:

- **ready**: Vercel `READY`; Railway `SUCCESS`, `SLEEPING`; Laravel Cloud `deployment.succeeded`;
  Fly.io `complete`
- **failed**: Vercel `ERROR`; Railway `FAILED`, `CRASHED`; Laravel Cloud `failed`, `build.failed`,
  `deployment.failed`; Fly.io `failed`
- **building**: everything in between (queued, building, deploying, …)

Cancelled, removed or skipped deployments are ignored. From the projects the light follows,
any failure gives red, otherwise anything building gives yellow, otherwise green.

## Requirements

- macOS 14 (Sonoma) or newer on Apple Silicon
- To build: Xcode 16 or newer (or its command line tools), Swift 6

## Run in development

```sh
git clone https://github.com/agustind/deployhero.git
cd deployhero
swift run
```

`swift run` starts the app straight from the build folder. Notifications and **Start at login**
need a real app bundle, so they're off there. Use the build below to try those.

## Build the app

```sh
scripts/build.sh
open dist/DeployHero.app
```

This produces `dist/DeployHero.app` (ad-hoc signed). Drag it into `/Applications` and open it.
Tick **Start at login** in its window to launch it automatically when you log in.

The first time a newly built binary reads your tokens, macOS asks for Keychain access. Click
**Always Allow**.

### Signed and notarized release builds

With a Developer ID Application certificate in your keychain and a `notarytool` profile
(`xcrun notarytool store-credentials <profile> --apple-id … --team-id …`):

```sh
export SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
export NOTARY_PROFILE=<profile>
scripts/build.sh --notarize   # sign, notarize and staple the .app and dist/deployhero-<version>.dmg
```

`scripts/build.sh --dmg` builds the `.dmg` without notarizing. Passing these as environment
variables keeps signing details out of the repo. The version comes from
`Resources/Info.plist`.

## Project layout

```
Package.swift                  Swift package (one executable target)
Resources/Info.plist           bundle id, version, menu-bar-only (LSUIElement)
scripts/build.sh               assembles, signs, notarizes and packages the .app
Sources/DeployHero/
  App.swift                    app delegate: windows, notifications, sleep/wake
  Monitor.swift                state: Keychain tokens, polling, the light, notifications
  StatusItem.swift             the menu bar dot and its menu
  SettingsView.swift           connect / settings window (SwiftUI)
  Settings.swift, Keychain.swift
  Providers/                   one file per platform, plus the shared HTTP helper
```

## Adding a platform

Create `Sources/DeployHero/Providers/<Name>.swift` with a type conforming to `Provider`
(documented in `Providers/Provider.swift`): `account(token:)` and
`deployments(token:scope:productionOnly:)`, returning states normalised to `.ready` / `.error` /
`.building` and dropping cancelled deployments. Then add a case to `ProviderID`. The menu,
window, notifications and settings pick it up automatically. Give it a badge letter and colour
in `Badge` in `SettingsView.swift`.
