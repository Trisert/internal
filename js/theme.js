// Theme handling: a stored choice wins; without one the operating system decides.
// The inline script in each page's <head> reads the same key before the first paint,
// so this module must not change the key or the value format (plain 'light' | 'dark').
export const THEME_KEY = 'j2050-theme';

const media = window.matchMedia('(prefers-color-scheme: dark)');
let explicit = storedTheme() !== null;

export function storedTheme() {
  try {
    const value = localStorage.getItem(THEME_KEY);
    return value === 'dark' || value === 'light' ? value : null;
  } catch {
    return null; // storage unavailable (private mode)
  }
}

export function systemTheme() {
  return media.matches ? 'dark' : 'light';
}

export function currentTheme() {
  return document.documentElement.dataset.theme === 'dark' ? 'dark' : 'light';
}

function syncButton(button) {
  const dark = currentTheme() === 'dark';
  button.setAttribute('aria-pressed', String(dark));
  button.setAttribute('aria-label', 'Dark mode');
  button.title = 'Dark mode';
  button.textContent = dark ? 'Light' : 'Dark';
}

export function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  document.querySelectorAll('[data-theme-toggle]').forEach(syncButton);
}

export function setTheme(theme) {
  explicit = true;
  stopFollowingSystem();
  try {
    localStorage.setItem(THEME_KEY, theme);
  } catch {
    // Storage unavailable: the choice lasts for this page only.
  }
  applyTheme(theme);
}

export function toggleTheme() {
  setTheme(currentTheme() === 'dark' ? 'light' : 'dark');
}

// Adds the toggle to a container; safe to call twice for the same container.
export function mountThemeToggle(container = document.body, { floating = false } = {}) {
  if (container.querySelector('[data-theme-toggle]')) return null;
  const button = document.createElement('button');
  button.type = 'button';
  button.className = floating ? 'theme-toggle floating' : 'theme-toggle';
  button.dataset.themeToggle = '';
  button.addEventListener('click', toggleTheme);
  container.appendChild(button);
  syncButton(button);
  return button;
}

// Keep following the OS while the user has no explicit preference.
const onSystemChange = () => {
  if (!explicit) applyTheme(systemTheme());
};
function stopFollowingSystem() {
  if (media.removeEventListener) media.removeEventListener('change', onSystemChange);
  else if (media.removeListener) media.removeListener(onSystemChange);
}
if (!explicit) {
  if (media.addEventListener) media.addEventListener('change', onSystemChange);
  else if (media.addListener) media.addListener(onSystemChange);
}

// Standalone pages (login, registration, password reset) have no shared header.
if (document.body.classList.contains('login-page')) {
  mountThemeToggle(document.body, { floating: true });
}
