# Changelog

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
