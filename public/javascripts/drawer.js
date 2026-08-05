// public/javascripts/drawer.js
//
// Progressive enhancement only. The drawer opens and closes with CSS via a
// hidden checkbox (see layout.css); this adds Escape-to-close and closes it
// after following a link. If this file fails to load, navigation still works.
(function () {
  var state = document.getElementById("drawer-state");
  if (!state) { return; }

  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") { state.checked = false; }
  });

  var drawer = document.getElementById("drawer");
  if (drawer) {
    drawer.addEventListener("click", function (e) {
      if (e.target.tagName === "A") { state.checked = false; }
    });
  }
})();
