// Shared fetch wrapper for the platform APIs. Throws an Error carrying
// `status` and `auth` (true only for a 401, i.e. a dead token) so callers
// can tell "sign out" apart from "try again later".

export async function request(url, { token, auth, method = 'GET', headers = {}, body, label = 'API' } = {}) {
  const res = await fetch(url, {
    method,
    headers: {
      accept: 'application/json',
      ...(auth || token ? { authorization: auth ?? 'Bearer ' + token } : {}),
      ...headers,
    },
    body,
  });
  const data = await res.json().catch(() => ({}));
  if (res.ok) return data;
  const err = new Error(data.error?.message ?? data.message ?? `${label} API ${res.status}`);
  err.status = res.status;
  err.body = data;
  err.auth = res.status === 401;
  throw err;
}

export const query = (params) => {
  const qs = new URLSearchParams(
    Object.entries(params).filter(([, v]) => v != null && v !== ''),
  ).toString();
  return qs ? '?' + qs : '';
};
