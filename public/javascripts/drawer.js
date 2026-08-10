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

  // Publish the header's height so the drawer and its scrim can start below
  // it instead of on top of it (see --topbar-h in layout.css). This is the
  // one thing CSS cannot work out for itself here: .topbar is a wrapping flex
  // row, so its height depends on the viewport width and on how long the
  // current locale's words happen to be -- 69px on a desktop, 125px at 390px.
  // Without this the stylesheet falls back to the one-row height, which is
  // right for a desktop and merely imperfect on a narrow phone; the menu
  // stays fully usable either way.
  var bar = document.querySelector(".topbar");
  if (bar) {
    var publish = function () {
      document.documentElement.style.setProperty(
        "--topbar-h", bar.getBoundingClientRect().height + "px");
    };
    publish();
    // A resize alone is not enough: the header also changes height when a
    // font finishes loading or a flash message is dismissed.
    if (window.ResizeObserver) {
      new ResizeObserver(publish).observe(bar);
    } else {
      window.addEventListener("resize", publish);
    }
  }
})();
