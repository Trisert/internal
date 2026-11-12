// Supabase client configuration.
// Only the PUBLIC key (publishable / anon) may appear here.
// NEVER put the secret / service_role key in this file or anywhere in the repository.
import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';

const SUPABASE_URL = 'https://aytqqficwdbtvgnigijg.supabase.co';
const SUPABASE_KEY = 'sb_publishable_DyR2KP0z15aU9_HOcgR3oQ_oj0lh81A';

// ---------------------------------------------------------------------------
// PREVIEW BRANCH ONLY — not part of the restyle PR.
// The app talks to the production Supabase project, so this deployment is
// read-only: sign-in still works, every data write is refused locally.
// ---------------------------------------------------------------------------
const PREVIEW_LABEL = 'PREVIEW · sola lettura — dati di produzione, scritture bloccate';

const originalFetch = window.fetch.bind(window);
window.fetch = (input, init = {}) => {
  const url = typeof input === 'string' ? input : (input && input.url) || '';
  const method = String(init.method || (input && input.method) || 'GET').toUpperCase();
  const supabaseCall = url.includes('.supabase.co');
  const authRead = url.includes('/auth/v1/token') || url.includes('/auth/v1/logout') || url.includes('/auth/v1/user');
  if (supabaseCall && method !== 'GET' && method !== 'HEAD' && !authRead) {
    console.warn('[preview] blocked write:', method, url);
    return Promise.resolve(new Response(
      JSON.stringify({ message: 'Preview in sola lettura: scritture bloccate.' }),
      { status: 403, headers: { 'Content-Type': 'application/json' } },
    ));
  }
  return originalFetch(input, init);
};

function mountPreviewBar() {
  const bar = document.createElement('div');
  bar.textContent = PREVIEW_LABEL;
  bar.style.cssText = [
    'position:fixed', 'left:0', 'right:0', 'bottom:0', 'z-index:9999',
    'padding:6px 12px', 'text-align:center', 'font:500 10px/1.6 ui-monospace,monospace',
    'letter-spacing:.08em', 'text-transform:uppercase',
    'background:#f07010', 'color:#1a0d00', 'pointer-events:none',
  ].join(';');
  document.body.appendChild(bar);
  document.body.style.paddingBottom = '32px';
  document.head.insertAdjacentHTML('beforeend', '<meta name="robots" content="noindex">');
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mountPreviewBar);
else mountPreviewBar();

export const supabase = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { flowType: 'implicit' },
});
