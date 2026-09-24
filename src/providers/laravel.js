// Laravel Cloud: JSON:API REST, organization API token. A token belongs to
// one organization, so there are no scopes to pick. An entry is one
// environment of an application.

import { request } from './http.js';

const API = 'https://cloud.laravel.com/api';
const MAX_PAGES = 5;

const STATES = {
  'deployment.succeeded': 'READY',
  'failed': 'ERROR',
  'build.failed': 'ERROR',
  'deployment.failed': 'ERROR',
  'cancelled': 'CANCELED',
  // pending, build.*, deployment.pending/created/queued/running → BUILDING
};

const cloud = (token, path) =>
  request(path.startsWith('http') ? path : API + path, { token, label: 'Laravel Cloud' });

// When a deployment was made. One with no timestamp at all is the newest
// there is if it's still in progress, and the oldest if it already ended
// (e.g. it failed before it ever started).
const startedAt = ({ attributes: a }) =>
  Date.parse(a.created_at ?? a.started_at ?? a.finished_at ?? '')
  || (STATES[a.status] ? -Infinity : Infinity);

async function latestDeployment(token, envId) {
  const page = await cloud(token, `/environments/${envId}/deployments`);
  let list = page.data ?? [];
  // The API doesn't document its order. If page one runs oldest → newest,
  // the latest deployment is on the last page.
  if (list.length > 1 && (page.meta?.last_page ?? 1) > 1 && page.links?.last
      && startedAt(list[0]) < startedAt(list[list.length - 1])) {
    list = (await cloud(token, page.links.last)).data ?? [];
  }
  // Like the other platforms, a cancelled deployment doesn't count.
  return list
    .filter((d) => STATES[d.attributes.status] !== 'CANCELED')
    .reduce((best, d) => (!best || startedAt(d) > startedAt(best) ? d : best), null);
}

export default {
  id: 'laravel',
  name: 'Laravel Cloud',
  host: 'cloud.laravel.com',
  scopeLabel: null,
  tokenUrl: 'https://cloud.laravel.com',
  tokenHelp: 'Navigate to your Laravel Cloud organization settings, click on the “API tokens” section in the sidebar, then click the “Create API Token” button.',
  dashboard: 'https://cloud.laravel.com',

  async account(token) {
    const { data } = await cloud(token, '/meta/organization');
    return { name: data.attributes.name, detail: 'Organization', scopes: [], defaultScope: '' };
  },

  async deployments(token, { productionOnly }) {
    const apps = [];
    const envs = new Map();
    let next = '/applications?include=environments,defaultEnvironment';
    for (let i = 0; next && i < MAX_PAGES; i++) {
      const page = await cloud(token, next);
      apps.push(...(page.data ?? []));
      for (const inc of page.included ?? []) if (inc.type === 'environments') envs.set(inc.id, inc);
      next = page.links?.next;
    }

    const targets = [];
    for (const app of apps) {
      const defaultId = app.relationships?.defaultEnvironment?.data?.id;
      for (const { id } of app.relationships?.environments?.data ?? []) {
        const env = envs.get(id);
        const name = env?.attributes.name ?? 'environment';
        if (productionOnly && id !== defaultId && name !== 'production') continue;
        targets.push({ app, env, id, name });
      }
    }

    const latest = await Promise.all(targets.map((t) => latestDeployment(token, t.id)));
    const out = [];
    targets.forEach(({ app, env, id, name }, i) => {
      const d = latest[i];
      if (!d) return;
      const a = d.attributes;
      const state = STATES[a.status] ?? 'BUILDING';
      if (state === 'CANCELED') return;
      const domain = env?.attributes.vanity_domain;
      out.push({
        key: id,
        uid: d.id,
        project: app.attributes.name,
        state,
        status: a.status.replace('.', ' '),
        target: name,
        created: Date.parse(a.started_at ?? a.finished_at ?? '') || Date.now(),
        url: domain ? 'https://' + domain : 'https://cloud.laravel.com',
        message: (state === 'ERROR' && a.failure_reason) || a.commit_message?.split('\n')[0] || null,
      });
    });
    return out;
  },
};
