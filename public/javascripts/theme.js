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
(function () {
  var stored = null;
  try { stored = localStorage.getItem("theme"); } catch (e) { /* private mode */ }

  var prefersLight = window.matchMedia &&
                     window.matchMedia("(prefers-color-scheme: light)").matches;

  document.documentElement.setAttribute(
    "data-theme", stored || (prefersLight ? "light" : "dark")
  );

  window.toggleTheme = function () {
    var next = document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    try { localStorage.setItem("theme", next); } catch (e) { /* ignore */ }
  };
})();
