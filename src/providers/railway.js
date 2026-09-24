// Railway: GraphQL API, account token. Scopes are workspaces; an entry is
// one service in one environment ("project / service", tagged with the env).

import { request } from './http.js';

const API = 'https://backboard.railway.com/graphql/v2';

const STATES = {
  SUCCESS: 'READY',
  SLEEPING: 'READY',
  FAILED: 'ERROR',
  CRASHED: 'ERROR',
  BUILDING: 'BUILDING',
  DEPLOYING: 'BUILDING',
  INITIALIZING: 'BUILDING',
  QUEUED: 'BUILDING',
  WAITING: 'BUILDING',
  NEEDS_APPROVAL: 'BUILDING',
  // Superseded, torn down or skipped — not the deployment that matters.
  REMOVED: 'CANCELED',
  REMOVING: 'CANCELED',
  SKIPPED: 'CANCELED',
};

const MAX_PROJECTS = 30;

async function gql(token, q, variables) {
  const res = await request(API, {
    token,
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ query: q, variables }),
    label: 'Railway',
  });
  if (res.errors?.length) throw new Error(res.errors[0].message);
  return res.data;
}

export default {
  id: 'railway',
  name: 'Railway',
  host: 'backboard.railway.com',
  scopeLabel: 'Workspace',
  tokenUrl: 'https://railway.com/account/tokens',
  tokenHelp: 'Use an account token (no workspace selected) so the app can list your workspaces.',
  dashboard: 'https://railway.com/dashboard',

  async account(token) {
    let me;
    try {
      ({ me } = await gql(token, 'query { me { name email username workspaces { id name } } }'));
    } catch (err) {
      // Workspace and project tokens can't read `me`.
      if (/not authorized/i.test(err.message)) {
        err.message = 'Railway rejected that token. It needs an account token (no workspace selected).';
        err.auth = true;
      }
      throw err;
    }
    const scopes = me.workspaces.map((w) => ({ id: w.id, name: w.name }));
    return {
      name: me.name || me.username || me.email,
      detail: me.email,
      scopes,
      defaultScope: scopes[0]?.id ?? '',
    };
  },

  async deployments(token, { scope, productionOnly }) {
    if (!scope) return [];
    const { workspace } = await gql(token, `query ($id: String!) {
      workspace(workspaceId: $id) { projects(first: ${MAX_PROJECTS}) { edges { node { id name deletedAt } } } }
    }`, { id: scope });
    const projects = workspace.projects.edges.map((e) => e.node).filter((p) => !p.deletedAt);
    if (!projects.length) return [];

    // One request for every project's recent deployments, aliased p0, p1, …
    const fields = 'id status createdAt staticUrl meta projectId serviceId environmentId service { name } environment { name }';
    const vars = projects.map((_, i) => `$p${i}: DeploymentListInput!`).join(', ');
    const body = projects.map((_, i) => `p${i}: deployments(first: 50, input: $p${i}) { edges { node { ${fields} } } }`).join('\n');
    const input = Object.fromEntries(projects.map((p, i) => [`p${i}`, { projectId: p.id }]));
    const data = await gql(token, `query (${vars}) { ${body} }`, input);

    const out = [];
    projects.forEach((p, i) => {
      // Newest first; keep the first live one per service + environment.
      const seen = new Set();
      for (const { node: d } of data[`p${i}`]?.edges ?? []) {
        const key = d.serviceId + ':' + d.environmentId;
        const state = STATES[d.status] ?? 'BUILDING';
        if (seen.has(key) || state === 'CANCELED') continue;
        seen.add(key);
        const env = d.environment?.name ?? '';
        if (productionOnly && env !== 'production') continue;
        out.push({
          key,
          uid: d.id,
          project: `${p.name} / ${d.service?.name ?? 'service'}`,
          state,
          status: d.status.toLowerCase().replace('_', ' '),
          target: env,
          created: Date.parse(d.createdAt),
          url: `https://railway.com/project/${d.projectId}/service/${d.serviceId}?environmentId=${d.environmentId}&id=${d.id}`,
          message: d.meta?.commitMessage?.split('\n')[0] ?? null,
        });
      }
    });
    return out;
  },
};
