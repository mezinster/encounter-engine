// public/javascripts/submit_once.js
//
// Stops a double-pressed submit button sending the same form twice.
//
// Reported from production on 2026-08-20: "Register" pressed twice created
// the account on the first request and answered the second with "this
// nickname is registered already" -- an error page for a signup that had in
// fact just succeeded. This app ships neither Turbo nor rails-ujs (see the
// GET /logout note in CLAUDE.md), so there is no framework already doing it.
//
// Progressive enhancement only, and deliberately NOT the real defence. Both
// test suites run without JavaScript, anyone can block this file, and a
// second request can be in flight before this handler runs at all -- so the
// guarantee lives in the unique indexes on users.email and users.nickname
// (migration 20260820130000). This is the half that keeps a real person from
// meeting a confusing error; that is the half that keeps two accounts from
// existing.
//
// Opt in per form with data-submit-once, rather than hooking every form on
// the site: a form that re-renders with validation errors must stay usable,
// and forms that navigate away (search, filters) have no double-submit
// problem to solve.
(function () {
  var forms = document.querySelectorAll("form[data-submit-once]");

  Array.prototype.forEach.call(forms, function (form) {
    form.addEventListener("submit", function () {
      var buttons = form.querySelectorAll("input[type=submit], button[type=submit]");

      // Deferred by a tick, and that is load-bearing rather than cautious: a
      // disabled control is not successful per the HTML form-submission
      // algorithm, so disabling it synchronously inside this handler drops
      // the button's own name/value from the request body. Rails' f.submit
      // sends `commit`, and a form that branches on it would silently take
      // the wrong branch.
      window.setTimeout(function () {
        Array.prototype.forEach.call(buttons, function (button) {
          button.disabled = true;
          if (button.dataset.submittingLabel) {
            if (button.tagName === "INPUT") {
              button.value = button.dataset.submittingLabel;
            } else {
              button.textContent = button.dataset.submittingLabel;
            }
          }
        });
      }, 0);
    });
  });
})();
