/* public/javascripts/live_region.js
 *
 * Refreshes one [data-live] region on an operator's live-game screen (standings,
 * live channel, full log, results) without reloading the page: every 20 s it
 * fetches the same URL (query string included, so the pager's page is kept),
 * takes the element with the region's id out of the response and swaps its
 * contents, keeping the scroll position.
 *
 * It HOLDS -- skips the tick, does not queue it -- while the tab is hidden,
 * while any <details> in the region is open (an intervention panel), or while
 * a form field has focus anywhere on the page; and re-checks after the fetch,
 * so a panel opened while a request was in flight is not swapped away. A
 * response without the region (an error page, the login page after the
 * session expired) swaps nothing: the old content stays and the stamp keeps
 * counting, so staleness is visible.
 *
 * Without JavaScript the page is the static page it always was; the status
 * line (shared/_live_status) stays hidden because it would be a lie.
 */
(function (root) {
  "use strict";

  var INTERVAL_MS = 20000;
  var STORAGE_KEY = "liveRegionPaused";

  function holdReason(doc, region) {
    if (doc.hidden) return "hidden";
    if (region.querySelector("details[open]")) return "panel";
    var active = doc.activeElement;
    if (active && /^(INPUT|SELECT|TEXTAREA)$/.test(active.tagName)) return "focus";
    return null;
  }

  function formatStamp(template, seconds) {
    return String(template).replace("%{seconds}", String(seconds));
  }

  // localStorage throws in some private windows and when site data is
  // blocked; a remembered pause is a convenience, never a requirement.
  function readPaused(storage) {
    try { return !!storage && storage.getItem(STORAGE_KEY) === "1"; } catch (e) { return false; }
  }

  function writePaused(storage, paused) {
    try {
      if (!storage) return;
      if (paused) storage.setItem(STORAGE_KEY, "1"); else storage.removeItem(STORAGE_KEY);
    } catch (e) { /* see readPaused */ }
  }

  function extractRegion(parse, html, id) {
    var parsed = parse(html);
    return parsed ? parsed.getElementById(id) : null;
  }

  function storageOf(win) {
    try { return win.localStorage; } catch (e) { return null; }
  }

  function start(doc, win) {
    var region = doc.querySelector("[data-live]");
    var status = doc.querySelector("[data-live-status]");
    if (!region || !region.id || !status || !win.fetch || !win.DOMParser) return;

    var stamp = status.querySelector("[data-live-stamp]");
    var toggle = status.querySelector("[data-live-toggle]");
    var storage = storageOf(win);
    var paused = readPaused(storage);
    var lastSwap = Date.now();

    function render() {
      stamp.textContent = formatStamp(status.getAttribute("data-template"),
                                      Math.round((Date.now() - lastSwap) / 1000));
      toggle.textContent = status.getAttribute(paused ? "data-resume-label" : "data-pause-label");
      toggle.setAttribute("aria-pressed", paused ? "true" : "false");
    }

    function parse(html) { return new win.DOMParser().parseFromString(html, "text/html"); }

    function tick() {
      if (paused || holdReason(doc, region)) return;
      win.fetch(win.location.href, { headers: { "X-Requested-With": "XMLHttpRequest" },
                                     credentials: "same-origin" })
        .then(function (response) { return response.ok ? response.text() : null; })
        .then(function (html) {
          if (!html || paused || holdReason(doc, region)) return;
          var fresh = extractRegion(parse, html, region.id);
          if (!fresh) return;
          var x = win.scrollX, y = win.scrollY;
          region.innerHTML = fresh.innerHTML;
          win.scrollTo(x, y);
          lastSwap = Date.now();
          render();
        })
        .catch(function () { /* keep the old content; the stamp shows its age */ });
    }

    toggle.addEventListener("click", function () {
      paused = !paused;
      writePaused(storage, paused);
      render();
    });

    status.hidden = false;
    render();
    win.setInterval(render, 1000);
    win.setInterval(tick, INTERVAL_MS);
  }

  var api = { holdReason: holdReason, formatStamp: formatStamp, readPaused: readPaused,
              writePaused: writePaused, extractRegion: extractRegion, start: start };

  if (typeof module !== "undefined" && module.exports) module.exports = api;
  root.LiveRegion = api;
  if (typeof document !== "undefined" && typeof window !== "undefined") start(document, window);
})(typeof window !== "undefined" ? window : this);
