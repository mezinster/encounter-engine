// public/javascripts/theme.js
//
// Runs inline in <head>, before first paint. A deferred script would let the
// page render in the wrong theme and then swap, which is worse than having no
// toggle at all.
//
// localStorage rather than a user column, deliberately: a theme is a
// device-and-lighting choice, not a personal one -- the same person wants dark
// in the street at night and light at a desk at noon -- and this also works
// for signed-out visitors with no migration.
//
// The theme-color <meta> must precede this script in <head>: it runs before
// first paint and reads the tag.
(function () {
  // Colours of the page background behind the browser chrome, per theme.
  // Must equal --bg in tokens.css for each theme; spec/theme_script_spec.rb
  // reads both files and fails if they drift.
  function themeColorFor(theme) { return theme === "light" ? "#faf8f6" : "#12100e"; }

  if (typeof document === "undefined") {
    if (typeof module !== "undefined" && module.exports) module.exports = { themeColorFor: themeColorFor };
    return;
  }

  function applyThemeColor(theme) {
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute("content", themeColorFor(theme));
  }

  var stored = null;
  try { stored = localStorage.getItem("theme"); } catch (e) { /* private mode */ }

  var prefersLight = window.matchMedia &&
                     window.matchMedia("(prefers-color-scheme: light)").matches;

  var initial = stored || (prefersLight ? "light" : "dark");
  document.documentElement.setAttribute("data-theme", initial);
  applyThemeColor(initial);

  window.toggleTheme = function () {
    var next = document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    applyThemeColor(next);
    try { localStorage.setItem("theme", next); } catch (e) { /* ignore */ }
  };
})();
