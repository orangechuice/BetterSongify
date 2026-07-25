// Chrome-extension service worker: performs translation fetches on behalf of
// the content script. Content scripts follow the page's CORS rules, and the
// unofficial translate endpoint sends no CORS headers, so the fetch must
// happen here, where host_permissions (see manifest.json) exempt it.

// Only proxy the one endpoint the extension actually uses — anything else is
// rejected so this worker can't be used as a general-purpose fetch proxy.
const ALLOWED_URL_PREFIX = "https://translate.googleapis.com/translate_a/single?";

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (
    message?.type !== "bs-translate" ||
    typeof message.url !== "string" ||
    !message.url.startsWith(ALLOWED_URL_PREFIX)
  ) {
    sendResponse({ ok: false, error: "Rejected request" });
    return false;
  }

  fetch(message.url)
    .then((response) => response.json())
    .then((payload) => sendResponse({ ok: true, payload }))
    .catch((error) => sendResponse({ ok: false, error: String(error) }));
  return true; // keep sendResponse alive for the async fetch
});
