// Vercel: REST API, personal access token. Scopes are the personal account
// (id '') and every team the token can see.

import { request, query } from './http.js';

const API = 'https://api.vercel.com';

const STATES = {
  READY: 'READY',
  ERROR: 'ERROR',
  BUILDING: 'BUILDING',
  QUEUED: 'BUILDING',
  INITIALIZING: 'BUILDING',
  CANCELED: 'CANCELED',
};

async function vercel(token, path, params = {}) {
  try {
    return await request(API + path + query(params), { token, label: 'Vercel' });
  } catch (err) {
    // Only a dead token signs us out; a 403 for one team's scope shouldn't.
    if (err.body?.error?.invalidToken === true) err.auth = true;
    throw err;
  }
}

export default {
  id: 'vercel',
  name: 'Vercel',
  host: 'api.vercel.com',
  scopeLabel: 'Team',
  tokenUrl: 'https://vercel.com/account/tokens',
  tokenHelp: 'Scope it to the team you want to watch.',
  dashboard: 'https://vercel.com',

  async account(token) {
    const [{ user: u }, { teams = [] }] = await Promise.all([
      vercel(token, '/v2/user'),
      vercel(token, '/v2/teams', { limit: 100 }),
    ]);
    const scopes = teams.map((t) => ({ id: t.id, name: t.name, slug: t.slug }));
    // Newer Vercel accounts have no personal scope — start on the default team.
    if (!u.defaultTeamId) scopes.unshift({ id: '', name: u.username + ' (personal)', slug: '' });
    return {
      name: u.name || u.username,
      detail: u.email,
      scopes,
      defaultScope: u.defaultTeamId ?? '',
    };
  },

  async deployments(token, { scope, productionOnly }) {
    const { deployments = [] } = await vercel(token, '/v6/deployments', {
      limit: 100,
      teamId: scope,
      target: productionOnly ? 'production' : null,
    });
    // The API returns newest first; keep the first live one we see per project.
    const byProject = new Map();
    for (const d of deployments) {
      const raw = d.state ?? d.readyState;
      const state = STATES[raw] ?? 'BUILDING';
      if (state === 'CANCELED' || byProject.has(d.name)) continue;
      byProject.set(d.name, {
        key: d.name,
        uid: d.uid,
        project: d.name,
        state,
        status: raw.toLowerCase(),
        target: d.target ?? 'preview',
        created: d.created ?? d.createdAt,
        url: d.inspectorUrl || (d.url ? 'https://' + d.url : null),
        message: d.meta?.githubCommitMessage?.split('\n')[0] ?? null,
      });
    }
    return [...byProject.values()];
  },

  dashboardUrl(account, scope) {
    const slug = account?.scopes.find((s) => s.id === scope)?.slug;
    return 'https://vercel.com/' + (slug ?? '');
  },
};
