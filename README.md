# DeployHero

A tiny macOS menu bar app that shows the status of your deployments on **Vercel**, **Railway**,
**Laravel Cloud** and **Fly.io** as one traffic light. Built with [tinyjs](https://tinyjs.app): a
JavaScript backend and a native webview, shipping as a ~6 MB `.app`.

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
- **Notifications.** Get a macOS notification when a deployment the app saw building
  finishes or fails.
- **Adaptive polling.** Checks every 10s while something is building and every 60s otherwise,
  and refreshes after the Mac wakes from sleep.
- **Start at login.** Optionally launch the app when you log in.

## Connecting platforms

Open **Settings…** and click **Connect** next to a platform, then paste a token. Each token is
stored in the **macOS Keychain**, never written to disk in plain text, and is only sent to that
platform's API. **Disconnect** removes it from the Keychain.

| Platform | Token | Sent to |
| -------- | ----- | ------- |
| Vercel | A personal access token from <https://vercel.com/account/tokens>. Scoping it to the team you want to watch is enough. | `api.vercel.com` |
| Railway | An **account** token from <https://railway.com/account/tokens>, created with no workspace selected. Workspace and project tokens can't list workspaces. | `backboard.railway.com` |
| Laravel Cloud | An API token from your organization settings → **API tokens**. Read access to applications, environments and deployments is enough. | `cloud.laravel.com` |
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

- macOS
- [tinyjs](https://tinyjs.app) 0.41.0 or newer:

  ```sh
  curl -fsSL https://tinyjs.app/install | sh
  ```

## Run in development

```sh
tinyjs dev
```

`tinyjs dev` launches the app with hot reload. Edit files in `src/` and it restarts itself.
Set `TINYJS_DEBUG=1` to log the traffic between the backend and the native side.

## Build the app

```sh
tinyjs build
```

This produces `dist/DeployHero.app` (ad-hoc signed). Drag it into `/Applications` and open it.
Tick **Start at login** in its window to launch it automatically when you log in.

The first time the built app runs, macOS asks for Keychain access, because it's a different
binary from the dev build.

### Signed and notarized release builds

With a Developer ID Application certificate in your keychain and a `notarytool` profile
(`xcrun notarytool store-credentials <profile> --apple-id … --team-id …`):

```sh
export TINYJS_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
export TINYJS_NOTARY_PROFILE=<profile>
tinyjs build --dmg       # sign with the Developer ID
tinyjs notarize --dmg    # submit to Apple, staple the ticket, rebuild the dmg
```

Passing these as environment variables keeps signing details out of `tinyjs.json`.

## Project layout

```
tinyjs.json            app config (name, bundle id, menu-bar-only "accessory" activation)
src/main.js            backend: Keychain tokens, polling, tray icon + menu
src/providers/         one module per platform, plus the shared fetch helper
src/icons.js           the four tray dots as base64 PNGs
src/frontend/          connect / settings window (HTML, CSS, JS)
types/                 editor type definitions for the tinyjs APIs
```

## Adding a platform

Create `src/providers/<name>.js` exporting the shape documented in
`src/providers/index.js` (`account(token)` and `deployments(token, { scope, productionOnly })`,
returning states normalised to `READY` / `ERROR` / `BUILDING`), then add it to the
`PROVIDERS` list there. The tray, window, notifications and settings pick it up
automatically. Give it a badge letter in `src/frontend/app.js` and a colour in `style.css`.
