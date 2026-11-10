'use strict';

const form = document.getElementById('token-form');
const errorNode = document.getElementById('token-error');

function showError(message) {
  errorNode.textContent = message;
  errorNode.hidden = false;
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  errorNode.hidden = true;
  const button = form.querySelector('button');
  button.disabled = true;
  try {
    const res = await fetch('/api/auth/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: document.getElementById('token').value }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      showError(data.error || 'Unbekannter Fehler');
      return;
    }
    sessionStorage.setItem('kintura_admin_token', data.token);
    location.replace('/admin');
  } catch {
    showError('Das Backend ist nicht erreichbar.');
  } finally {
    button.disabled = false;
  }
});
