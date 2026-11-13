// Shared authentication, profile and navigation helpers.
import { supabase } from './config.js';
import { icon } from './icons.js';
import { mountThemeToggle } from './theme.js';

export const MIN_PASSWORD_LENGTH = 12;
export const ALLOWED_DOMAINS = ['studenti.unipd.it', 'unipd.it'];

// Absolute URL of a page of this site (works in the /internal/ sub-folder).
export function pageUrl(file) {
  return new URL(file, window.location.href).href;
}

export function isAllowedEmail(email) {
  const domain = email.trim().toLowerCase().split('@')[1] ?? '';
  return ALLOWED_DOMAINS.includes(domain);
}

export function checkPassword(password, confirmation) {
  if (password.length < MIN_PASSWORD_LENGTH) {
    return `The password shall contain at least ${MIN_PASSWORD_LENGTH} characters.`;
  }
  if (password !== confirmation) return 'The two passwords do not match.';
  return null;
}

// Translates technical error messages into messages for the user.
const ERROR_MESSAGES = {
  'Invalid login credentials': 'Invalid email or password.',
  'Email not confirmed': 'Email not confirmed. Open the link in the confirmation email first.',
  'Database error saving new user':
    'Registration refused. Only @studenti.unipd.it and @unipd.it addresses are allowed.',
  'Email domain not allowed':
    'Only @studenti.unipd.it and @unipd.it addresses are allowed.',
  'Not authorized': 'Operation reserved to administrators.',
  'Account not active': 'Your account is not active.',
  'At least one active admin is required': 'At least one active administrator is required.',
  'Member not found': 'Member not found.',
  'Leader shall be an active teamleader or admin':
    'The leader shall be an active member with role teamleader or admin.',
};

export function friendlyError(error) {
  const message = error?.message ?? String(error);
  if (/rate limit/i.test(message)) {
    return 'Too many emails sent in a short time. Try again later.';
  }
  return ERROR_MESSAGES[message] ?? message;
}

// Session and profile of the current user ({ session: null } if logged out).
export async function getSessionProfile() {
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) return { session: null, profile: null };
  const { data: profile, error } = await supabase
    .from('profiles')
    .select('id, email, first_name, last_name, full_name, role, status')
    .eq('id', session.user.id)
    .single();
  if (error) throw error;
  return { session, profile };
}

// A member may use the site only when name and surname are set
// and the account has been approved.
export function isReady(profile) {
  return Boolean(profile.first_name && profile.last_name && profile.status === 'active');
}

export function landingPage(profile) {
  return isReady(profile) ? 'shifts.html' : 'welcome.html';
}

export function displayName(profile) {
  return profile.full_name ?? profile.email ?? '';
}

export async function signOut() {
  await supabase.auth.signOut();
  window.location.replace('index.html');
}

// Common header: navigation, user name, role, logout.
export function renderHeader(profile, activePage) {
  const header = document.getElementById('app-header');
  header.innerHTML = `
    <a class="brand" href="shifts.html">
      <span class="brand-logo" role="img" aria-label="J2050">
        <img class="logo-on-light" src="img/j2050-logo-light.png" width="239" height="88" alt="">
        <img class="logo-on-dark" src="img/j2050-logo-dark.png" width="241" height="88" alt="">
      </span>
      <span class="brand-sub">Team Management</span>
    </a>
    <nav>
      <a href="shifts.html" data-page="shifts">Lab shifts</a>
      <a href="gantt.html" data-page="gantt">Gantt</a>
      <a href="stats.html" data-page="stats" data-admin hidden>Stats</a>
      <a href="members.html" data-page="members" data-admin hidden>Members</a>
      <a href="account.html" data-page="account">Account</a>
    </nav>
    <div class="user">
      <span id="user-name"></span>
      <span id="user-role" class="badge"></span>
      <button id="logout-btn" type="button" class="secondary btn-icon" aria-label="Log out" title="Log out">${icon('log-out')}</button>
    </div>`;
  if (profile.role === 'admin') {
    header.querySelectorAll('[data-admin]').forEach((el) => { el.hidden = false; });
  }
  const activeLink = header.querySelector(`[data-page="${activePage}"]`);
  activeLink?.classList.add('active');
  activeLink?.scrollIntoView({ block: 'nearest', inline: 'center' });
  header.querySelector('#user-name').textContent = displayName(profile);
  header.querySelector('#user-role').textContent = profile.role;
  header.querySelector('#logout-btn').addEventListener('click', signOut);
  mountThemeToggle(header.querySelector('.user'));
}

// Start-up sequence of a protected page.
// Returns the profile, or null if the user is redirected elsewhere.
export async function initProtectedPage(activePage, { adminOnly = false } = {}) {
  let result;
  try {
    result = await getSessionProfile();
  } catch (err) {
    console.error(err);
    document.getElementById('app-main').textContent =
      'Profile not found or not readable. Contact an administrator.';
    return null;
  }
  if (!result.session) { window.location.replace('index.html'); return null; }
  if (!isReady(result.profile)) { window.location.replace('welcome.html'); return null; }
  if (adminOnly && result.profile.role !== 'admin') {
    window.location.replace('shifts.html');
    return null;
  }
  renderHeader(result.profile, activePage);
  return result.profile;
}

// Shows a message in an element; kind: 'error' | 'success' | 'info'.
export function showMessage(element, text, kind = 'error') {
  element.textContent = text;
  element.className = `message ${kind}`;
  element.hidden = !text;
}
