# Changelog

## 0.5.0 — 2026-10-29

### New
- **Several teams per platform.** Follow your personal Vercel account and any Vercel teams
  together, or several Railway workspaces or Fly.io organizations, with one token per platform.
  Tick them in the settings window; the menu shows a section for each. If one team can't be
  reached, the others keep showing.
- To see your personal account and your teams, the Vercel token needs Full Account scope.

### Upgrading
Your followed team and "Light follows" choices carry over.

## 0.4.1 — 2026-10-15

### Fixed
- **Auto refresh** could stop until you clicked Refresh. A request that stalled (for example
  after sleep or a network change) held up the refresh, and the next check wasn't scheduled
  until it ended. Each request now gives up
  after 30s, polling keeps running through sleep, and a failed check retries after 10s instead
  of 60s.
- **The menu** now lists every building or failed deployment, not only the newest 10 per
  platform, so it always shows what made the light yellow or red. A building deployment also
  shows its status, such as "needs approval" or "queued".

## 0.4.0 — 2026-09-29

### New
- **Rewritten as a native Swift app** (AppKit + SwiftUI) instead of a tinyjs web view, at about a
  fifth of the download size. Your tokens and settings carry over; macOS asks once for Keychain
  access for the new binary.
- **About** uses the standard macOS About panel.
- **Clicking a notification** opens that deployment.
- Needs macOS 14 or newer.

## 0.3.2 — 2026-09-24

### Fixed
- **Notifications** now fire for deployments that start and finish between two checks. Before,
  a quick deploy that went from queued to ready within the 60s idle poll never produced a
  "deployed" (or "failed") notification.

## 0.3.1 — 2026-09-24

### Fixed
- **Laravel Cloud:** each environment's light now reflects its latest deployment. An older failed
  deployment could keep the light red after a newer deploy had succeeded.
- **Laravel Cloud:** a cancelled deployment no longer hides the environment; the latest
  non-cancelled deployment is shown instead, as on the other platforms.
- Clearer steps for creating a Laravel Cloud API token.

## 0.3.0 — 2026-09-24

DeployHero is the successor to
[Vercel Menubar Status](https://github.com/agustind/vercel-menubar-status-app): one menu bar
traffic light for your deployments across several platforms.

### New
- **Railway, Laravel Cloud and Fly.io** join Vercel. Connect any mix of them with an access token
  each; the light rolls them all up and the menu groups projects by platform.
- **Scopes per platform:** a Vercel team, a Railway workspace or a Fly.io organization.
- **Production only** now also covers Railway environments and Laravel Cloud's default
  environment.
- **Light follows** works across platforms, so you can follow a Vercel project and a Railway
  service together.

### Upgrading from Vercel Menubar Status
DeployHero is a separate app with its own Keychain entry, so paste your Vercel token again after
installing. You can then delete the old app.
