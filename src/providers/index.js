// Every platform the app can watch. A provider exposes:
//
//   id, name, host        identity, and the only host its token is sent to
//   scopeLabel            what its scopes are called (null: no picker)
//   tokenUrl, tokenHelp   where and how to create a token
//   dashboard             fallback dashboard URL
//   account(token)        → { name, detail, scopes: [{ id, name }], defaultScope }
//   deployments(token, { scope, productionOnly })
//                         → the latest deployment per project:
//                           [{ key, uid, project, state, status, target, created, url, message }]
//                           state is READY | ERROR | BUILDING
//   dashboardUrl?(account, scope)
//
// Errors with `auth: true` mean the token is dead and the platform gets
// disconnected.

import vercel from './vercel.js';
import railway from './railway.js';
import laravel from './laravel.js';
import fly from './fly.js';

export const PROVIDERS = [vercel, railway, laravel, fly];
export const PROVIDER = Object.fromEntries(PROVIDERS.map((p) => [p.id, p]));
