const $ = (id) => document.getElementById(id);
// Escape anything that goes into innerHTML — project names and commit
// messages come from the network.
const esc = (s) => String(s ?? '').replace(/[&<>"']/g,
  (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const STATE_CLASS = { READY: 'green', ERROR: 'red', BUILDING: 'yellow' };
const BADGE = { vercel: '▲', railway: 'R', laravel: 'L', fly: 'F' };

// Platform cards are built once and then updated in place, so a half-typed
// token or an open connect form survives the state pushes from each poll.
const cards = new Map();
const open = new Set();

function card(p) {
  if (cards.has(p.id)) return cards.get(p.id);
  const el = document.createElement('div');
  el.className = 'card';
  el.dataset.provider = p.id;
  el.innerHTML = `
    <div class="cardHead">
      <span class="badge ${esc(p.id)}">${esc(BADGE[p.id] ?? p.name[0])}</span>
      <div class="who">
        <div class="name">${esc(p.name)}</div>
        <div class="muted small acct"></div>
      </div>
      <button class="link toggle"></button>
    </div>
    <label class="field scopeRow" hidden>
      <span>${esc(p.scopeLabel ?? '')}</span>
      <select class="scope"></select>
    </label>
    <form class="connectForm" hidden>
      <p class="muted small">
        <a href="#" class="tokenLink">Create a ${esc(p.name)} token</a>. ${esc(p.tokenHelp)}
        It's only sent to <code>${esc(p.host)}</code>.
      </p>
      <div class="row">
        <input type="password" class="token" placeholder="${esc(p.name)} access token" autocomplete="off" spellcheck="false">
        <button type="submit">Connect</button>
      </div>
    </form>
    <div class="err"></div>`;
  const q = (sel) => el.querySelector(sel);

  q('.tokenLink').addEventListener('click', (e) => {
    e.preventDefault();
    tiny.api.call('openUrl', { url: p.tokenUrl });
  });
  q('.toggle').addEventListener('click', async () => {
    if (el.classList.contains('connected')) {
      if (await tiny.dialog.confirm(`Disconnect ${p.name}?`, { detail: 'The token is removed from your Keychain.' }))
        render(await tiny.api.call('disconnect', { provider: p.id }));
      return;
    }
    open.has(p.id) ? open.delete(p.id) : open.add(p.id);
    q('.connectForm').hidden = !open.has(p.id);
    q('.toggle').textContent = open.has(p.id) ? 'Cancel' : 'Connect';
    if (open.has(p.id)) q('.token').focus();
  });
  q('.connectForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = q('button[type=submit]');
    q('.err').textContent = '';
    btn.disabled = true;
    try {
      const s = await tiny.api.call('connect', { provider: p.id, token: q('.token').value });
      q('.token').value = '';
      open.delete(p.id);
      render(s);
    } catch (err) {
      q('.err').textContent = err.message ?? String(err);
    } finally {
      btn.disabled = false;
    }
  });
  q('.scope').addEventListener('change', async () =>
    render(await tiny.api.call('setSettings', { scope: { provider: p.id, id: q('.scope').value } })));

  $('platforms').appendChild(el);
  cards.set(p.id, el);
  return el;
}

function renderCard(p) {
  const el = card(p);
  const q = (sel) => el.querySelector(sel);
  el.classList.toggle('connected', p.connected);
  q('.acct').textContent = p.connected
    ? [p.account?.name, p.account?.detail].filter(Boolean).join(' · ') || 'Connected'
    : 'Not connected';
  q('.toggle').textContent = p.connected ? 'Disconnect' : open.has(p.id) ? 'Cancel' : 'Connect';
  q('.connectForm').hidden = p.connected || !open.has(p.id);

  const scopes = p.account?.scopes ?? [];
  q('.scopeRow').hidden = !p.connected || !p.scopeLabel || scopes.length < 2;
  q('.scope').innerHTML = scopes
    .map((s) => `<option value="${esc(s.id)}"${p.scope === s.id ? ' selected' : ''}>${esc(s.name)}</option>`)
    .join('');
  // Connect errors are written by the submit handler; keep them until the next try.
  if (p.connected) q('.err').textContent = p.error ?? '';
}

function render(s) {
  $('version').textContent = 'v' + s.version;
  $('aboutVersion').textContent = 'Version ' + s.version;
  $('light').className = 'light ' + s.light;
  s.providers.forEach(renderCard);
  $('intro').hidden = s.signedIn;
  $('main').hidden = !s.signedIn;
  if (!s.signedIn) return;

  $('prodOnly').checked = s.settings.productionOnly;
  // With "all" followed every box is ticked; ticking narrows from there.
  $('follows').textContent = s.settings.watch == null ? 'all projects' : s.follows;
  $('followAll').hidden = s.settings.watch == null;
  $('projects').innerHTML = s.projects.length
    ? s.projects.map((p) => `
      <li data-url="${esc(p.url)}" class="${p.watched ? '' : 'unwatched'}">
        <input type="checkbox" class="watch" data-key="${esc(p.key)}"
          title="Include in the menu bar light"${p.watched && s.settings.watch != null ? ' checked' : ''}>
        <span class="dot ${STATE_CLASS[p.state] ?? 'gray'}"></span>
        <div class="proj">
          <div><b>${esc(p.project)}</b> <span class="tag">${esc(p.target)}</span></div>
          <div class="muted small">${esc(p.message ?? p.status)}</div>
        </div>
        <div class="meta">
          <span class="badge small ${esc(p.provider)}" title="${esc(p.providerName)}">${esc(BADGE[p.provider] ?? '?')}</span>
          <span class="muted small">${esc(p.ago)}</span>
        </div>
      </li>`).join('')
    : '<li class="muted">No deployments yet.</li>';
  $('checked').textContent = s.lastChecked
    ? 'Checked ' + new Date(s.lastChecked).toLocaleTimeString()
    : '';
}

tiny.api.on('state', render);

const showAbout = (show) => { $('about').hidden = !show; };
tiny.api.on('about', () => showAbout(true));
$('aboutBtn').addEventListener('click', () => showAbout(true));
$('aboutClose').addEventListener('click', () => showAbout(false));
$('about').addEventListener('click', (e) => { if (e.target === $('about')) showAbout(false); });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') showAbout(false); });
document.addEventListener('click', (e) => {
  const a = e.target.closest('a.ext');
  if (!a) return;
  e.preventDefault();
  tiny.api.call('openUrl', { url: a.dataset.url });
});

$('prodOnly').addEventListener('change', async () =>
  render(await tiny.api.call('setSettings', { productionOnly: $('prodOnly').checked })));
$('refresh').addEventListener('click', async () => render(await tiny.api.call('refresh')));

$('followAll').addEventListener('click', async () =>
  render(await tiny.api.call('toggleWatch', { key: null })));

$('projects').addEventListener('click', async (e) => {
  if (e.target.classList.contains('watch')) {
    render(await tiny.api.call('toggleWatch', { key: e.target.dataset.key }));
    return;
  }
  const url = e.target.closest('li')?.dataset.url;
  if (url) tiny.api.call('openUrl', { url });
});

// Start at login. 'unsupported' under `tinyjs dev`, so the row stays hidden there.
function renderLoginItem(status) {
  $('loginItemRow').hidden = status === 'unsupported';
  $('loginItem').checked = status === 'enabled' || status === 'requires-approval';
  $('loginItemNote').textContent = status === 'requires-approval'
    ? 'Allow it in System Settings → General → Login Items' : '';
}
$('loginItem').addEventListener('change', async () => {
  try {
    renderLoginItem(await tiny.app.launchAtLogin.set($('loginItem').checked));
  } catch {
    renderLoginItem(await tiny.app.launchAtLogin.get());
  }
});
tiny.app.launchAtLogin.get().then(renderLoginItem, () => renderLoginItem('unsupported'));

tiny.api.call('getState').then(render);
