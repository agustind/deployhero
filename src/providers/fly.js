// Fly.io: GraphQL API. Takes a personal access token or an org token
// ("FlyV1 fm2_…"). Scopes are organizations; an entry is one app and its
// latest release.

import { request } from './http.js';

const API = 'https://api.fly.io/graphql';

// Release statuses flyctl writes: running → complete | failed | interrupted.
const STATES = {
  complete: 'READY',
  succeeded: 'READY',
  successful: 'READY',
  failed: 'ERROR',
  interrupted: 'CANCELED',
  pending: 'BUILDING',
  running: 'BUILDING',
};

// Macaroon tokens go in as-is with their FlyV1 scheme; the rest are bearer.
function authHeader(token) {
  if (token.startsWith('FlyV1 ')) return token;
  if (token.startsWith('fm1') || token.startsWith('fm2')) return 'FlyV1 ' + token;
  return 'Bearer ' + token;
}

async function gql(token, q, variables) {
  const res = await request(API, {
    auth: authHeader(token),
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ query: q, variables }),
    label: 'Fly.io',
  });
  if (res.errors?.length) {
    const err = new Error(res.errors[0].message);
    err.auth = /must be authenticated|unauthorized/i.test(err.message);
    throw err;
  }
  return res.data;
}

export default {
  id: 'fly',
  name: 'Fly.io',
  host: 'api.fly.io',
  scopeLabel: 'Org',
  tokenUrl: 'https://fly.io/user/personal_access_tokens',
  tokenHelp: 'A personal access token, or an org token from `fly tokens create org`.',
  dashboard: 'https://fly.io/dashboard',

  async account(token) {
    const { viewer, organizations } = await gql(token, `query {
      viewer { name email }
      organizations(first: 100) { nodes { id slug name type } }
    }`);
    const scopes = organizations.nodes.map((o) => ({ id: o.slug, name: o.name, slug: o.slug }));
    const personal = organizations.nodes.find((o) => o.type === 'PERSONAL');
    return {
      name: viewer?.name || viewer?.email || scopes[0]?.name || 'Fly.io',
      detail: viewer?.email ?? '',
      scopes,
      defaultScope: personal?.slug ?? scopes[0]?.id ?? '',
    };
  },

  // Fly has no preview deployments, so productionOnly doesn't narrow anything.
  async deployments(token, { scope }) {
    if (!scope) return [];
    const { organization } = await gql(token, `query ($slug: String!) {
      organization(slug: $slug) {
        apps(first: 100) { nodes {
          name deployed
          releases(first: 1) { nodes { id version status description createdAt } }
        } }
      }
    }`, { slug: scope });
    const out = [];
    for (const app of organization?.apps.nodes ?? []) {
      const r = app.releases.nodes[0];
      if (!r) continue;
      const state = STATES[r.status] ?? 'BUILDING';
      if (state === 'CANCELED') continue;
      out.push({
        key: app.name,
        uid: r.id,
        project: app.name,
        state,
        status: r.status,
        target: 'v' + r.version,
        created: Date.parse(r.createdAt),
        url: `https://fly.io/apps/${app.name}`,
        message: r.description || null,
      });
    }
    return out;
  },

  dashboardUrl(account, scope) {
    return scope ? `https://fly.io/dashboard/${scope}` : this.dashboard;
  },
};
