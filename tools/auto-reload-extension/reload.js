// Reload this page on a fixed interval.
//
// A content script runs again on every load, so one setTimeout is enough:
// each reload re-arms the next one. There is no state to carry across reloads
// and nothing to clean up.
//
// Chrome throttles timers in background windows, which stalls this too. When
// the window is not the foreground one, launch Chrome with
// --disable-background-timer-throttling (see split-chrome.ps1 for the full set).

const INTERVAL_MINUTES = 30;

setTimeout(() => location.reload(), INTERVAL_MINUTES * 60 * 1000);
