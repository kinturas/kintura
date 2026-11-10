'use strict';

// All data is inserted through textContent, so stored text can never become markup.
const $ = (id) => document.getElementById(id);
const TOKEN_KEY = 'kintura_admin_token';
const POLL_MS = 3000;

const FAMILY_TYPES = { family: 'Familie', friends: 'Freundeskreis', relatives: 'Verwandtschaft', workgroup: 'Arbeitsgruppe' };
const FAMILY_ROLES = { manager: 'Eltern', user: 'Erwachsenes Kind', restrict_user: 'Kind', guest: 'Gast' };
const OTHER_ROLES = { manager: 'Manager', user: 'User', restrict_user: 'Restricted', guest: 'Gast' };

let token = sessionStorage.getItem(TOKEN_KEY);
let requestId = null;
let pollTimer = null;
let oldestLogId = null;

const roleLabel = (type, role) => (type === 'family' ? FAMILY_ROLES : OTHER_ROLES)[role] || role;

function formatDate(value) {
  const date = new Date(value);
  return isNaN(date) ? value : date.toLocaleString('de-DE', { dateStyle: 'medium', timeStyle: 'short' });
}

function el(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}

function setError(id, message) {
  $(id).textContent = message || '';
  $(id).hidden = !message;
}

async function api(method, path, body) {
  const headers = {};
  if (token) headers.Authorization = 'Bearer ' + token;
  if (body) headers['Content-Type'] = 'application/json';
  let res;
  try {
    res = await fetch(path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  } catch {
    throw Object.assign(new Error('Das Backend ist nicht erreichbar.'), { status: 0 });
  }
  const data = res.status === 204 ? null : await res.json().catch(() => ({}));
  if (!res.ok) {
    throw Object.assign(new Error((data && data.error) || 'Unbekannter Fehler'), { status: res.status });
  }
  return data;
}

function show(screen) {
  for (const id of ['login', 'activate', 'denied', 'board']) $(id).hidden = id !== screen;
}

function setToken(value) {
  token = value;
  if (value) sessionStorage.setItem(TOKEN_KEY, value);
  else sessionStorage.removeItem(TOKEN_KEY);
}

// Login: the same flow as in the app, code or mail link.

function stopPolling() {
  clearInterval(pollTimer);
  pollTimer = null;
}

function showEmailStep() {
  stopPolling();
  requestId = null;
  $('email-form').hidden = false;
  $('code-form').hidden = true;
  $('code').value = '';
  setError('login-error');
  show('login');
}

async function handleLoginResult(result) {
  if (result.status === 'pending') return;
  stopPolling();
  if (result.status === 'authenticated') {
    setToken(result.token);
    await start();
  } else if (result.status === 'registration_required') {
    showEmailStep();
    setError('login-error', 'Für diese Adresse gibt es noch kein Konto. Registriere dich zuerst in der App.');
  }
}

async function poll() {
  const id = requestId;
  try {
    const result = await api('POST', '/api/auth/poll', { request_id: id });
    if (id === requestId && pollTimer) await handleLoginResult(result);
  } catch (err) {
    // Short network problems are ignored; the next poll tries again.
    if (err.status === 410 && id === requestId && pollTimer) {
      showEmailStep();
      setError('login-error', err.message);
    }
  }
}

$('email-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  setError('login-error');
  const button = event.target.querySelector('button');
  button.disabled = true;
  try {
    const email = $('email').value.trim();
    const result = await api('POST', '/api/auth/request', { email });
    requestId = result.request_id;
    $('sent-to').textContent = email;
    $('email-form').hidden = true;
    $('code-form').hidden = false;
    $('code').focus();
    pollTimer = setInterval(poll, POLL_MS);
  } catch (err) {
    setError('login-error', err.message);
  } finally {
    button.disabled = false;
  }
});

$('code-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  setError('login-error');
  const button = event.target.querySelector('button');
  button.disabled = true;
  try {
    await handleLoginResult(await api('POST', '/api/auth/verify', { request_id: requestId, code: $('code').value }));
  } catch (err) {
    setError('login-error', err.message);
  } finally {
    button.disabled = false;
  }
});

$('code-back').addEventListener('click', showEmailStep);

// Unlocking with the API key.

$('key-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  setError('key-error');
  const button = event.target.querySelector('button');
  button.disabled = true;
  try {
    await api('POST', '/api/admin/activate', { key: $('key').value });
    $('key').value = '';
    await start();
  } catch (err) {
    if (err.status === 401) return logout();
    setError('key-error', err.message);
  } finally {
    button.disabled = false;
  }
});

async function logout() {
  if (token) await api('POST', '/api/auth/logout').catch(() => {});
  setToken(null);
  showEmailStep();
}

document.querySelectorAll('.logout').forEach((button) => button.addEventListener('click', logout));

// Dashboard views.

function table(headers, rows) {
  const wrap = el('div', undefined, 'table-wrap');
  const tableNode = el('table');
  const head = el('tr');
  for (const header of headers) head.append(el('th', header));
  const thead = el('thead');
  thead.append(head);
  const tbody = el('tbody');
  tbody.append(...rows);
  tableNode.append(thead, tbody);
  wrap.append(tableNode);
  return wrap;
}

function row(...cells) {
  const tr = el('tr');
  for (const cell of cells) tr.append(cell instanceof Node ? cell : el('td', cell));
  return tr;
}

function nameCell(name, ...badges) {
  const td = el('td');
  td.append(name);
  for (const badge of badges) if (badge) td.append(el('span', badge, 'badge'));
  return td;
}

function plural(count, one, many) {
  return count + ' ' + (count === 1 ? one : many);
}

async function loadFamilies() {
  const families = await api('GET', '/api/admin/families');
  const section = $('families');
  section.replaceChildren(el('h2', 'Kreise (' + families.length + ')'));
  if (!families.length) section.append(el('p', 'Es gibt noch keine Kreise.', 'muted'));
  for (const family of families) {
    const card = el('article', undefined, 'card');
    card.append(
      el('h3', family.name),
      el('p', (FAMILY_TYPES[family.type] || family.type) + ' · ' + plural(family.members.length, 'Mitglied', 'Mitglieder') +
        ' · angelegt am ' + formatDate(family.created_at)),
    );
    if (family.members.length) {
      card.append(table(['Name', 'E-Mail', 'Rolle'], family.members.map((member) => row(
        nameCell(member.name, member.is_admin && 'Admin', member.is_sysadmin && 'Sysadmin'),
        member.email,
        roleLabel(family.type, member.role),
      ))));
    }
    section.append(card);
  }
}

async function loadUsers() {
  const users = await api('GET', '/api/admin/users');
  const section = $('users');
  section.replaceChildren(el('h2', 'Mitglieder (' + users.length + ')'));
  if (!users.length) {
    section.append(el('p', 'Es gibt noch keine Mitglieder.', 'muted'));
    return;
  }
  section.append(table(['Name', 'E-Mail', 'Kreise', 'Dabei seit'], users.map((user) => {
    const circles = el('td');
    if (!user.families.length) circles.append(el('span', 'Kein Kreis', 'muted'));
    for (const family of user.families) {
      circles.append(el('div', family.name + ' (' + roleLabel(family.type, family.role) + (family.is_admin ? ', Admin' : '') + ')'));
    }
    return row(nameCell(user.name, user.is_sysadmin && 'Sysadmin'), user.email, circles, el('td', formatDate(user.created_at), 'nowrap'));
  })));
}

function logRow(entry) {
  return row(
    el('td', formatDate(entry.created_at), 'nowrap'),
    entry.email || '–',
    entry.family_name || '–',
    el('td', entry.endpoint || '–', 'nowrap'),
    entry.status ? String(entry.status) : '–',
    el('td', entry.message, 'message'),
  );
}

async function loadLog(more) {
  const page = await api('GET', '/api/admin/log' + (more ? '?before=' + oldestLogId : ''));
  const holder = $('log-table');
  if (more) {
    holder.querySelector('tbody').append(...page.entries.map(logRow));
  } else if (page.entries.length) {
    holder.replaceChildren(table(['Datum', 'Benutzer', 'Kreis', 'Endpunkt', 'Status', 'Meldung'], page.entries.map(logRow)));
  } else {
    const empty = el('div', 'Bisher wurden keine Fehler protokolliert.', 'empty');
    const wrap = el('div', undefined, 'table-wrap');
    wrap.append(empty);
    holder.replaceChildren(wrap);
  }
  if (page.entries.length) oldestLogId = page.entries[page.entries.length - 1].id;
  $('log-more').hidden = !page.has_more;
}

function pageCard(page) {
  const form = el('form', undefined, 'card');
  const label = el('label', page.title);
  label.htmlFor = 'page-' + page.slug;
  const text = el('textarea');
  text.id = 'page-' + page.slug;
  text.value = page.content;
  text.spellcheck = true;
  const button = el('button', 'Speichern');
  button.type = 'submit';
  const status = el('span', 'Zuletzt geändert am ' + formatDate(page.updated_at), 'muted');
  const saveRow = el('div', undefined, 'save-row');
  saveRow.append(button, status);
  form.append(label, el('p', 'In der App unter „Über“ und auf der Anmeldeseite.', 'muted'), text, saveRow);
  text.addEventListener('input', () => { status.textContent = 'Nicht gespeichert'; });
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    button.disabled = true;
    try {
      const result = await api('PUT', '/api/admin/pages/' + encodeURIComponent(page.slug), { content: text.value });
      status.textContent = 'Gespeichert am ' + formatDate(result.updated_at);
    } catch (err) {
      if (err.status === 401 || err.status === 403) return start();
      status.textContent = err.message;
    } finally {
      button.disabled = false;
    }
  });
  return form;
}

async function loadPages() {
  const pages = await api('GET', '/api/admin/pages');
  $('pages').replaceChildren(
    el('h2', 'Seiten'),
    el('p', 'Markdown: Leerzeile für einen neuen Absatz, ## für Überschriften, - für Listen, **fett** und [Text](https://…) für Links. ' +
      'Ein einfacher Zeilenumbruch bleibt erhalten, etwa in einer Anschrift.', 'muted'),
    ...pages.map(pageCard),
  );
}

const VIEWS = { families: loadFamilies, users: loadUsers, pages: loadPages, log: () => loadLog(false) };

async function run(action) {
  setError('board-error');
  try {
    await action();
  } catch (err) {
    if (err.status === 401 || err.status === 403) return start();
    setError('board-error', err.message);
  }
}

function openView(view) {
  for (const id of Object.keys(VIEWS)) $(id).hidden = id !== view;
  document.querySelectorAll('nav button').forEach((button) => {
    if (button.dataset.view === view) button.setAttribute('aria-current', 'page');
    else button.removeAttribute('aria-current');
  });
  return run(VIEWS[view]);
}

document.querySelectorAll('nav button').forEach((button) => {
  button.addEventListener('click', () => openView(button.dataset.view));
});
$('log-refresh').addEventListener('click', () => run(() => loadLog(false)));
$('log-more').addEventListener('click', () => run(() => loadLog(true)));

// Decides which screen fits the current session.
async function start() {
  if (!token) return showEmailStep();
  let status;
  try {
    status = await api('GET', '/api/admin/status');
  } catch (err) {
    if (err.status === 401) {
      setToken(null);
      return showEmailStep();
    }
    if (err.status === 403) return show('denied');
    showEmailStep();
    return setError('login-error', err.message);
  }
  if (!status.activated) {
    $('key-missing').hidden = status.key_configured;
    $('key-form').hidden = !status.key_configured;
    return show('activate');
  }
  $('who').textContent = status.email;
  show('board');
  await openView('families');
}

start();
