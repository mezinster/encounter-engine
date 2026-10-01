/* public/javascripts/live_region.js
 *
 * Refreshes one [data-live] region on an operator's live-game screen (standings,
 * live channel, full log, results) without reloading the page: every 20 s it
 * fetches the same URL (query string included, so the pager's page is kept),
 * takes the element with the region's id out of the response and swaps its
 * contents, keeping the scroll position.
 *
 * It HOLDS -- skips the tick, does not queue it -- while the tab is hidden,
 * while any <details> in the region is open (an intervention panel), while
 * focus is inside the region (except on a closed panel's summary), or while a
 * form field has focus anywhere on the page; and re-checks after the fetch,
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
  // Shorter than the interval, so a stuck request never spans two ticks.
  var TIMEOUT_MS = 15000;
  var STORAGE_KEY = "liveRegionPaused";

  // Desktop Chrome focuses a clicked link, so plain focus would hold refresh
  // after a click and a bfcache Back. Only keyboard focus (:focus-visible)
  // counts; if the browser cannot say, keep the safe behaviour and hold.
  function keyboardFocused(el) {
    try {
      if (el.matches) return !!el.matches(":focus-visible");
    } catch (e) { /* unsupported selector: fall through */ }
    return true;
  }

  function holdReason(doc, region) {
    if (doc.hidden) return "hidden";
    if (region.querySelector("details[open]")) return "panel";
    var active = doc.activeElement;
    if (active && /^(INPUT|SELECT|TEXTAREA)$/.test(active.tagName)) return "focus";
    // Keyboard focus on a link or button inside the region: a swap would destroy it.
    // Exception: a closed panel's <summary>. Chrome and Android Firefox focus
    // a tapped summary, so closing a panel leaves focus inside the region;
    // holding there would pause refresh indefinitely, and a closed panel has
    // nothing editable to lose. (An open one is caught by "panel" above.)
    if (active && active !== doc.body && region.contains && region.contains(active)) {
      var closedSummary = active.tagName === "SUMMARY" && active.parentNode &&
                          active.parentNode.tagName === "DETAILS" && !active.parentNode.open;
      if (!closedSummary && keyboardFocused(active)) return "focus";
    }
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

    var inFlight = false;

    // One request at a time: a tick while one is pending is skipped, not
    // queued, so an older response can never overwrite a newer one. Each
    // request is aborted after TIMEOUT_MS; without AbortController (old
    // browsers) the request is merely ignored on arrival, and the guard
    // still prevents overlap.
    function tick() {
      if (inFlight || paused || holdReason(doc, region)) return;
      inFlight = true;
      var aborted = false;
      var controller = win.AbortController ? new win.AbortController() : null;
      var timer = null;
      function finish() {
        if (timer !== null) { win.clearTimeout(timer); timer = null; }
        inFlight = false;
      }
      timer = win.setTimeout(function () {
        timer = null;
        aborted = true;
        if (controller) controller.abort();
        finish();
      }, TIMEOUT_MS);
      var options = { headers: { "X-Requested-With": "XMLHttpRequest" }, credentials: "same-origin" };
      if (controller) options.signal = controller.signal;
      win.fetch(win.location.href, options)
        .then(function (response) { return response.ok ? response.text() : null; })
        .then(function (html) {
          if (aborted) return;
          finish();
          if (!html || paused || holdReason(doc, region)) return;
          var fresh = extractRegion(parse, html, region.id);
          if (!fresh) return;
          var x = win.scrollX, y = win.scrollY;
          region.innerHTML = fresh.innerHTML;
          win.scrollTo(x, y);
          lastSwap = Date.now();
          render();
        })
        .catch(function () { if (!aborted) finish(); /* keep the old content; the stamp shows its age */ });
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
    return { tick: tick }; // test hook; the browser ignores the return value
  }

  var api = { holdReason: holdReason, formatStamp: formatStamp, readPaused: readPaused,
              writePaused: writePaused, extractRegion: extractRegion, start: start };

  if (typeof module !== "undefined" && module.exports) module.exports = api;
  root.LiveRegion = api;
  if (typeof document !== "undefined" && typeof window !== "undefined") start(document, window);
})(typeof window !== "undefined" ? window : this);
