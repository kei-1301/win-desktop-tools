// Watch this page and reload it when the screen shows an error.
//
// This exists so the dashboard can run in your everyday Chrome profile. The
// DevTools-based watcher (split-chrome.ps1) needs --remote-debugging-port, which
// Chrome refuses on the default profile, and signed-in cookies cannot be copied
// to another profile either. Doing the watching from inside the page sidesteps
// both: no debugging port, no separate profile, logins intact.
//
// A content script restarts on every load, so state that must outlive a reload
// lives in sessionStorage (per tab, cleared when the window closes).
//
// Chrome throttles timers in background windows, which would stall this. Launch
// Chrome with --disable-background-timer-throttling (split-chrome.ps1 does).

// ---- settings -------------------------------------------------------------

const CHECK_INTERVAL_MS = 3000;

// Text that means "this page is broken". The /i is deliberate: without it a
// lowercase "an error occurred" slips through, while split-chrome.ps1 catches it
// (PowerShell's -match ignores case), and the two would disagree.
//
// Note what is NOT covered: Chrome's own network error screen says
// "このサイトにアクセスできません" / "DNS_PROBE_FINISHED_NXDOMAIN" and contains
// none of these words -- and a content script is not injected into it anyway,
// since chrome-error:// pages are off limits to extensions. Add server-side
// wordings your system actually shows.
const ERROR_PATTERN =
  /error|exception|ERR_|DNS_PROBE|Bad Gateway|Service Unavailable|エラー|失敗|タイムアウト|アクセスできません/i;

// Treat a page with no visible text as broken (blank / hung screen).
const CHECK_BLANK = true;

// Reload on a timer as well. 0 disables it.
const INTERVAL_MINUTES = 0;

// After reloading, leave the page alone this long before judging it again.
// Doubles while the error persists so an outage is not hammered forever.
const BASE_GRACE_MS = 30 * 1000;
const MAX_GRACE_MS = 600 * 1000;

// ---- state carried across reloads -----------------------------------------

const STATE_KEY = "__autoReloadState";

function loadState() {
  try {
    return JSON.parse(sessionStorage.getItem(STATE_KEY)) || {};
  } catch (e) {
    return {};
  }
}

function saveState(state) {
  try {
    sessionStorage.setItem(STATE_KEY, JSON.stringify(state));
  } catch (e) {
    // Private mode or a blocked origin: fall back to no back-off rather than
    // breaking the reload behaviour entirely.
  }
}

// ---- watching -------------------------------------------------------------

function isBroken() {
  const text = document.body ? document.body.innerText || "" : "";
  if (ERROR_PATTERN.test(text)) return "error";
  if (CHECK_BLANK && text.replace(/\s+/g, "").length === 0) return "blank";
  return null;
}

function reloadNow(state, reason) {
  state.lastReload = Date.now();
  state.strikes = (state.strikes || 0) + 1;
  if (state.strikes >= 2) {
    state.grace = Math.min((state.grace || BASE_GRACE_MS) * 2, MAX_GRACE_MS);
  }
  saveState(state);
  console.log("[auto-reload] reloading:", reason);
  location.reload();
}

function check() {
  // Mid-navigation the body is legitimately empty; judging it here would make
  // every reload trigger the next one.
  if (document.readyState !== "complete") return;

  const state = loadState();
  const reason = isBroken();

  if (!reason) {
    if (state.strikes) {
      state.strikes = 0;
      state.grace = BASE_GRACE_MS;
      saveState(state);
    }
    if (INTERVAL_MINUTES > 0) {
      const due = (state.lastReload || 0) + INTERVAL_MINUTES * 60 * 1000;
      if (Date.now() >= due) reloadNow(state, "timer");
    }
    return;
  }

  const grace = state.grace || BASE_GRACE_MS;
  if (Date.now() - (state.lastReload || 0) < grace) return;

  reloadNow(state, reason);
}

// No initial grace period: a page that is already broken when the window opens
// should be reloaded at the first check, not one BASE_GRACE_MS later. Loading
// pages are excluded by the readyState guard, and repeated failures still back
// off, so nothing here can spin.
setInterval(check, CHECK_INTERVAL_MS);
