/*
 * PhoenixKitInbox's JavaScript, declared by `js_sources/0` and folded by
 * core's `:phoenix_kit_js_sources` compiler into the host's
 * `phoenix_kit_modules.js`. Hand-written, no build step: it ships as it is.
 *
 * It holds what the templates used to do with inline handlers
 * (`onmousedown="event.preventDefault()"`). A Content-Security-Policy without
 * 'unsafe-inline' blocks those and no nonce can be put on an attribute, so
 * the markup names what it wants and one listener on the document does it.
 * No LiveView hook: the buttons are rows of a list that is rebuilt on every
 * keystroke, and a delegated listener needs no `phx-hook` and no id on them.
 *
 *   data-pki-keep-focus     pressing the mouse on it does not move the focus
 *                           (a recipient suggestion: the field it belongs to
 *                           must not blur before the click arrives)
 */
(function () {
  "use strict";

  if (typeof window === "undefined" || typeof document === "undefined") return;

  // The global `js_sources/0` names. This bundle has no hooks, but the
  // compiler folds `window.PhoenixKitInboxHooks` into `PhoenixKitHooks`.
  window.PhoenixKitInboxHooks = window.PhoenixKitInboxHooks || {};

  // A host may load the bundle twice (the modules file and an import of its
  // own): one listener is enough.
  if (window.__pkInboxLoaded) return;
  window.__pkInboxLoaded = true;

  function closest(target, selector) {
    return target && typeof target.closest === "function" ? target.closest(selector) : null;
  }

  document.addEventListener("mousedown", function (event) {
    if (closest(event.target, "[data-pki-keep-focus]")) event.preventDefault();
  });
})();
