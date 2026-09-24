// Deployment status light for the macOS menu bar, across Vercel, Railway,
// Laravel Cloud and Fly.io.
//
// The backend owns everything: the tokens (Keychain), polling each connected
// platform, and the tray icon/menu. The window (src/frontend) is only the
// connect / settings screen and talks to us through `api` below. Each
// platform lives in src/providers and hands back the latest deployment per
// project in one shared shape.

import { ICONS } from './icons.js';
import { PROVIDERS, PROVIDER } from './providers/index.js';

const APP_NAME = 'DeployHero';
const POLL_IDLE = 60_000;   // nothing in flight
const POLL_BUSY = 10_000;   // something is building — check more often

const tokenKey = (id) => id + '-token';

let app;
// Per connected platform: { token, account, error, items }.
let conns = {};
// scopes: provider id -> scope id (team, workspace, org).
// watch: null = the light follows every project, else only these keys
// ("<provider>:<project key>").
let settings = { productionOnly: false, watch: null, scopes: {} };
let projects = [];        // latest deployment per project, all platforms, newest first
let light = 'gray';
let lastChecked = null;
let timer = null;
let iconPaths = {};
let seenStates = null;    // uid -> state, for "finished" notifications

const connected = () => PROVIDERS.filter((p) => conns[p.id]?.token).map((p) => p.id);
const errors = () => connected().filter((id) => conns[id].error).map((id) => [id, conns[id].error]);
const scopeOf = (id) => settings.scopes[id] ?? '';

// --- deployments ------------------------------------------------------------

async function loadAccount(id) {
  const c = conns[id];
  c.account = await PROVIDER[id].account(c.token);
  const { scopes, defaultScope } = c.account;
  if (!scopes.length) settings.scopes[id] = '';
  else if (!scopes.some((s) => s.id === settings.scopes[id])) settings.scopes[id] = defaultScope;
}

async function refreshOne(id) {
  const c = conns[id];
  try {
    if (!c.account) await loadAccount(id);
    const items = await PROVIDER[id].deployments(c.token, {
      scope: scopeOf(id),
      productionOnly: settings.productionOnly,
    });
    c.items = items.map((p) => ({ ...p, provider: id, key: id + ':' + p.key, uid: id + ':' + p.uid }));
    c.error = null;
  } catch (e) {
    c.items = [];
    c.error = e.message;
    if (e.auth) {
      await disconnect(id);
      return true;
    }
  }
  return false;
}

const isWatched = (key) => settings.watch == null || settings.watch.includes(key);

function lightFor(list) {
  if (list.some((p) => p.state === 'ERROR')) return 'red';
  if (list.some((p) => p.state === 'BUILDING')) return 'yellow';
  return list.length ? 'green' : 'gray';
}

function computeLight() {
  const ids = connected();
  // Every platform unreachable: we know nothing.
  if (!ids.length || ids.every((id) => conns[id].error)) return 'gray';
  return lightFor(projects.filter((p) => isWatched(p.key)));
}

// --- polling ---------------------------------------------------------------

async function refresh() {
  clearTimeout(timer);
  timer = null;
  const ids = connected();
  const signedOut = (await Promise.all(ids.map(refreshOne))).some(Boolean);
  projects = connected()
    .flatMap((id) => conns[id].items ?? [])
    .sort((a, b) => b.created - a.created);
  notifyFinished(projects);
  light = computeLight();
  lastChecked = Date.now();
  render();
  if (signedOut) app.window('main').show();
  if (!connected().length) return;
  clearTimeout(timer);   // an overlapping refresh may have scheduled one
  timer = setTimeout(refresh, light === 'yellow' ? POLL_BUSY : POLL_IDLE);
}

// A notification when a deployment we saw building lands (or fails).
function notifyFinished(next) {
  const prev = seenStates;
  seenStates = new Map(next.map((p) => [p.uid, p.state]));
  if (!prev) return;   // first poll after launch/connect — don't spam history
  for (const p of next) {
    const before = prev.get(p.uid);
    if (before !== 'BUILDING' || p.state === 'BUILDING') continue;
    const where = PROVIDER[p.provider].name;
    if (p.state === 'ERROR') app.notify({ title: `❌ ${p.project} failed`, body: p.message ?? `${where} deployment errored` });
    if (p.state === 'READY') app.notify({ title: `✅ ${p.project} deployed`, body: p.message ?? `${p.target} is live on ${where}` });
  }
}

// --- tray ------------------------------------------------------------------

const DOT = { READY: '🟢', ERROR: '🔴', BUILDING: '🟡' };
const SUMMARY = {
  green: 'All deployments ready',
  yellow: 'Deployment in progress…',
  red: 'A deployment failed',
  gray: 'No deployments',
};
const SINGLE = { green: 'ready', yellow: 'building…', red: 'failed', gray: 'no deployments' };

const labelOf = (key) => projects.find((p) => p.key === key)?.project ?? key.split(':').slice(1).join(':');

// "saturn-app: ready" when the light follows one project, else the roll-up.
function summary() {
  if (settings.watch?.length === 1) return labelOf(settings.watch[0]) + ': ' + SINGLE[light];
  return SUMMARY[light];
}

function followsLabel() {
  if (settings.watch == null) return 'All projects';
  return settings.watch.length === 1 ? labelOf(settings.watch[0]) : settings.watch.length + ' projects';
}

// Picking a project while following all narrows to just it; after that,
// clicks toggle. Unticking the last one goes back to all.
function toggleWatch(key) {
  if (key == null || settings.watch == null) settings.watch = key == null ? null : [key];
  else if (settings.watch.includes(key)) settings.watch = settings.watch.filter((k) => k !== key);
  else settings.watch = [...settings.watch, key];
  if (settings.watch?.length === 0) settings.watch = null;
}

function ago(ms) {
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (s < 60) return 'just now';
  if (s < 3600) return Math.floor(s / 60) + 'm ago';
  if (s < 86400) return Math.floor(s / 3600) + 'h ago';
  return Math.floor(s / 86400) + 'd ago';
}

function scopeName(id) {
  const account = conns[id]?.account;
  return account?.scopes.find((s) => s.id === scopeOf(id))?.name ?? account?.name ?? '';
}

// "saturn-app (staging)": the environment, when it isn't the obvious one.
const nameOf = (p) =>
  p.project + (p.target && !/^(production|preview|v\d+)$/.test(p.target) ? ` (${p.target})` : '');

const itemLabel = (p) => `${DOT[p.state] ?? '⚪️'}  ${nameOf(p)} — ${ago(p.created)}`;

function render() {
  const menu = [];
  const ids = connected();
  if (!ids.length) {
    menu.push({ id: 'status', label: 'No platforms connected', enabled: false });
    menu.push({ id: 'settings', label: 'Connect a Platform…' });
  } else {
    const errs = errors();
    menu.push({ id: 'status', label: errs.length === ids.length ? '⚠️ Can’t check deployments' : summary(), enabled: false });
    for (const [id, msg] of errs) {
      menu.push({ id: 'err:' + id, label: `⚠️ ${PROVIDER[id].name}: ${msg.slice(0, 60)}`, enabled: false });
    }
    // One platform: a flat list like before. Several: grouped under headers.
    for (const id of ids) {
      const list = projects.filter((p) => p.provider === id).slice(0, ids.length > 1 ? 10 : 15);
      const scope = scopeName(id);
      menu.push({ separator: true });
      menu.push({ id: 'h:' + id, label: ids.length > 1 ? PROVIDER[id].name + (scope ? ' · ' + scope : '') : 'Scope: ' + scope, enabled: false });
      for (const p of list) menu.push({ id: 'p:' + projects.indexOf(p), label: itemLabel(p) });
    }
    menu.push({ separator: true });
    if (projects.length) {
      menu.push({
        id: 'follows',
        label: 'Light follows: ' + followsLabel(),
        submenu: [
          { id: 'w:all', label: 'All projects', checked: settings.watch == null },
          ...ids.flatMap((id) => {
            const list = projects.filter((p) => p.provider === id).slice(0, 30);
            if (!list.length) return [];
            return [
              { separator: true },
              ...(ids.length > 1 ? [{ id: 'wh:' + id, label: PROVIDER[id].name, enabled: false }] : []),
              ...list.map((p) => ({
                id: 'w:' + projects.indexOf(p),
                label: nameOf(p),
                checked: settings.watch?.includes(p.key) ?? false,
              })),
            ];
          }),
        ],
      });
      menu.push({ separator: true });
    }
    menu.push({ id: 'refresh', label: 'Refresh Now', key: 'r' });
    if (ids.length === 1) {
      menu.push({ id: 'd:' + ids[0], label: `Open ${PROVIDER[ids[0]].name} Dashboard` });
    } else {
      menu.push({
        id: 'dashboards',
        label: 'Open Dashboard',
        submenu: ids.map((id) => ({ id: 'd:' + id, label: PROVIDER[id].name })),
      });
    }
    menu.push({ id: 'settings', label: 'Settings…', key: ',' });
  }
  menu.push({ separator: true });
  menu.push({ id: 'about', label: 'About ' + APP_NAME });
  menu.push({ id: 'quit', label: 'Quit', key: 'q' });

  app.tray.set({
    icon: iconPaths[light],
    template: false,   // keep the red/yellow/green instead of a mono silhouette
    tooltip: APP_NAME + ': ' + (ids.length ? summary() : 'no platforms connected'),
    menu,
  });
  app.push('state', publicState());
}

function publicState() {
  return {
    version: app.info.version,
    signedIn: connected().length > 0,
    settings,
    light,
    follows: followsLabel(),
    lastChecked,
    providers: PROVIDERS.map((p) => {
      const c = conns[p.id];
      return {
        id: p.id,
        name: p.name,
        host: p.host,
        scopeLabel: p.scopeLabel,
        tokenUrl: p.tokenUrl,
        tokenHelp: p.tokenHelp,
        connected: !!c?.token,
        account: c?.account ?? null,
        scope: scopeOf(p.id),
        error: c?.error ?? null,
      };
    }),
    projects: projects.map((p) => ({
      ...p,
      providerName: PROVIDER[p.provider].name,
      ago: ago(p.created),
      watched: isWatched(p.key),
    })),
  };
}

async function writeIcons() {
  const dir = app.paths.cache + '/tray';
  await tjs.makeDir(dir, { recursive: true });
  for (const [name, b64] of Object.entries(ICONS)) {
    const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    const path = `${dir}/${name}.png`;
    await tjs.writeFile(path, bytes);
    iconPaths[name] = path;
  }
}

// Forget a platform's projects from the watch list (scope change, disconnect).
function unwatchProvider(id) {
  if (settings.watch == null) return;
  settings.watch = settings.watch.filter((k) => !k.startsWith(id + ':'));
  if (!settings.watch.length) settings.watch = null;
}

async function disconnect(id) {
  delete conns[id];
  delete settings.scopes[id];
  unwatchProvider(id);
  projects = projects.filter((p) => p.provider !== id);
  seenStates = null;
  light = computeLight();
  if (!connected().length) clearTimeout(timer);
  await app.secrets.delete(tokenKey(id));
  await app.store.set('settings', settings);
  render();
}

// --- page api --------------------------------------------------------------

export const api = {
  getState: async () => publicState(),

  async connect({ provider: id, token }) {
    const p = PROVIDER[id];
    if (!p) throw new Error('Unknown platform');
    token = String(token ?? '').trim();
    if (!token) throw new Error(`Paste a ${p.name} token first`);
    const prev = conns[id];
    conns[id] = { token, account: null, error: null, items: [] };
    try {
      await loadAccount(id);
    } catch (e) {
      if (prev) conns[id] = prev;
      else delete conns[id];
      throw e.auth && !/token/i.test(e.message) ? new Error(`That token was rejected by ${p.name}`) : e;
    }
    await app.secrets.set(tokenKey(id), token);
    await app.store.set('settings', settings);
    seenStates = null;
    await refresh();
    return publicState();
  },

  disconnect: async ({ provider }) => (await disconnect(provider), publicState()),

  async setSettings(patch) {
    if (patch.scope) {
      const { provider: id, id: scope } = patch.scope;
      if (conns[id] && (scope ?? '') !== scopeOf(id)) {
        settings.scopes[id] = scope ?? '';
        unwatchProvider(id);   // project keys don't carry across scopes
      }
    }
    if ('productionOnly' in patch) settings.productionOnly = !!patch.productionOnly;
    await app.store.set('settings', settings);
    seenStates = null;
    await refresh();
    return publicState();
  },

  // Only the light changes — no need to hit the APIs again.
  async toggleWatch({ key }) {
    toggleWatch(key ?? null);
    await app.store.set('settings', settings);
    light = computeLight();
    render();
    return publicState();
  },

  refresh: async () => (await refresh(), publicState()),

  openUrl: async ({ url }) => {
    if (!/^https:\/\//.test(url)) throw new Error('refusing non-https url');
    return app.shell.open(url);
  },
};

// --- lifecycle -------------------------------------------------------------

// Settings saved by the Vercel-only app: teamId, and watch as project names.
function migrate(saved) {
  const s = { ...settings, ...saved, scopes: { ...(saved.scopes ?? {}) } };
  if ('teamId' in s) {
    if (!('vercel' in s.scopes)) s.scopes.vercel = s.teamId ?? '';
    delete s.teamId;
  }
  if (s.watch) s.watch = s.watch.map((k) => (k.includes(':') ? k : 'vercel:' + k));
  return s;
}

export async function init(a) {
  app = a;
  app.setHideOnClose(true);
  await writeIcons();
  settings = migrate((await app.store.get('settings')) ?? {});
  for (const p of PROVIDERS) {
    const token = await app.secrets.get(tokenKey(p.id));
    if (token) conns[p.id] = { token, account: null, error: null, items: [] };
  }
  render();
  if (connected().length) refresh();
  else app.window('main').show();
  // Keep the "5m ago" labels honest between polls.
  setInterval(() => connected().length && render(), 60_000);
}

export function onTray(id, a) {
  if (id === 'quit') return a.quit();
  if (id === 'refresh') return refresh();
  if (id === 'settings') return a.window('main').show();
  if (id === 'about') {
    a.window('main').show();
    return a.push('about', null);
  }
  if (id?.startsWith('d:')) {
    const p = PROVIDER[id.slice(2)];
    const c = conns[p?.id];
    if (!p) return;
    return api.openUrl({ url: p.dashboardUrl?.(c?.account, scopeOf(p.id)) ?? p.dashboard });
  }
  if (id === 'w:all') return api.toggleWatch({ key: null });
  if (id?.startsWith('w:')) return api.toggleWatch({ key: projects[Number(id.slice(2))]?.key });
  if (id?.startsWith('p:')) {
    const p = projects[Number(id.slice(2))];
    if (p?.url) api.openUrl({ url: p.url });
  }
}

export function onSystem(kind) {
  if (kind === 'wake') refresh();
  if (kind === 'sleep') clearTimeout(timer);
}
