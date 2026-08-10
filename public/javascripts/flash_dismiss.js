// public/javascripts/flash_dismiss.js
//
// Takes a stale message off the screen. Used by exactly one thing today: the
// "your code was correct" flash on the play screen, in the case where that
// code moved the team to the NEXT task. The message is then about a question
// the page no longer shows -- «Код 'Рецепт суши' -- верный» pinned under a
// question about penicillin -- and the view cannot simply omit it, because
// features/game-passing/stepping-next-level.feature:26-27 is frozen and
// requires it on the advanced page. So it is rendered, labelled with the task
// it belongs to, and removed here a few seconds later.
//
// Removing it rather than hiding it: .play-pinned never shrinks (screens.css),
// so a hidden-but-present flash would go on reserving its height in the one
// column that must not waste any.
//
// Plain DOM and no jQuery even though the play screen loads jQuery 1.3.2 for
// the hint poller -- there is nothing here that needs it, and this file is
// also cheap enough to be safe on a phone mid-race.
//
// The suites never run this. Capybara's rack-test driver executes no
// JavaScript, so the flash stays in the document for every assertion in
// features/ and spec/; what those pin is the data-dismiss-after attribute
// this reads (spec/requests/answer_feedback_spec.rb). Keep the attribute name
// and this file in step.
(function () {
  function arm(el) {
    var delay = parseInt(el.getAttribute("data-dismiss-after"), 10);
    if (!(delay > 0)) return;

    window.setTimeout(function () {
      if (el.parentNode) el.parentNode.removeChild(el);
    }, delay);
  }

  function start() {
    var nodes = document.querySelectorAll("[data-dismiss-after]");
    for (var i = 0; i < nodes.length; i++) arm(nodes[i]);
  }

  // The script tag sits at the top of the view, so the flash below it does not
  // exist yet at parse time.
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
})();
