var LevelHintUpdater = function() {
    var
    countdownValue = 0
    ,gameId = 0
    ,intervalId = null;

    var
    $hintsContainer
    ,$countdownContainer
    ,$countdownTimerText
    ,$loadingIndicator;

    var
    start = function(initialCountdownValue) {
        countdownValue = initialCountdownValue;

        updateCountdown();
        intervalId = setInterval(updateCountdown, 1000);

        setTimeout(stop, countdownValue * 1000 + 1000);
    }

    ,stop = function() {
        clearInterval(intervalId);
        countdownValue = 0;

        loadHint();
    }

    ,updateCountdown = function() {
        var minutes = countdownValue / 60
        ,seconds = 0;

        if ( minutes > 0 && Math.floor(minutes) != minutes ) {
            minutes = Math.floor(minutes);
            seconds = countdownValue % 60;
        } else {
            seconds = countdownValue;
        }

        $countdownTimerText.text(minutes + ' мин ' + seconds + ' сек');
        countdownValue--;
    }

    ,showCountdownContainer = function() {
        $countdownContainer.show();
    }

    ,hideCountdownContainer = function() {
        $countdownContainer.hide();
    }

    ,showLoadIndicator = function() {
        $loadingIndicator.show();
    }

    ,hideLoadIndicator = function() {
        $loadingIndicator.hide();
    }

    ,appendHint = function(hintNum, hintText, hintLabel, attachments, attachmentsLabel) {
        // Nodes, not an HTML string: hint text is author-written and reaches
        // this function raw from /play/:game_id/tip. jQuery .append() with a
        // string parses it as markup, so concatenating here made every hint a
        // stored-XSS vector against every playing team. The server-rendered
        // path (show_current_level.html.erb) escapes, so text is the correct
        // and matching behaviour. "card" matches the class that view puts on
        // its own fieldset.
        var fieldset = document.createElement("fieldset");
        fieldset.className = "card";

        var legend = document.createElement("legend");
        // hintLabel is server-translated (t("game_passings.show_current_level.hint_label")),
        // via I18n at the interface locale -- NOT a hardcoded literal here.
        // This line used to read `"Подсказка #" + hintNum`, a hardcoded
        // Russian word, so a hint that fired after page load showed one
        // Russian word to every non-Russian player regardless of their
        // chosen locale. Pre-existing bug, fixed here because this exact
        // function was already being touched for the attachments feature.
        legend.textContent = hintLabel + " #" + hintNum;

        fieldset.appendChild(legend);
        fieldset.appendChild(document.createTextNode(hintText));

        // Attachments: same authorization-filtered {url, image_url, alt}
        // array shared/_attachment_strip.html.erb would have rendered for
        // this hint, had it fired before page load (see
        // GamePassingsController#hint_attachments_json). Built the same
        // way as hintText above -- createElement/setAttribute/textContent
        // only. image_url is present only when GameFile#existing_web_variant
        // exists server-side (not a PDF, not a GIF, not a missing variant);
        // absent, this falls back to a generic link exactly like the
        // server-rendered strip does, never a broken <img>.
        if ( attachments && attachments.length > 0 ) {
            var strip = document.createElement("div");
            strip.className = "attachment-strip";
            strip.setAttribute("role", "group");
            if ( attachmentsLabel ) {
                strip.setAttribute("aria-label", attachmentsLabel);
            }

            for ( var i = 0; i < attachments.length; i++ ) {
                var attachment = attachments[i];

                // No scheme check on url/image_url before setAttribute below:
                // both are built server-side by game_file_delivery_path (a
                // Rails named-route helper -- see hint_attachments_json),
                // never by concatenating anything author-supplied into a
                // URL. The only per-attachment value an author controls is
                // alt (the filename), which never reaches href/src. If this
                // payload ever grows a field that puts user input INTO a
                // URL -- a linked external source, say -- this comment stops
                // being true and a same-origin/scheme allowlist check
                // belongs here before that field is trusted.
                var link = document.createElement("a");
                link.setAttribute("href", attachment.url);

                if ( attachment.image_url ) {
                    link.className = "attachment-item";

                    var img = document.createElement("img");
                    img.setAttribute("src", attachment.image_url);
                    img.setAttribute("alt", attachment.alt);
                    img.className = "attachment-image";

                    link.appendChild(img);
                } else {
                    link.className = "attachment-item attachment-item--generic";

                    var icon = document.createElement("span");
                    icon.className = "attachment-generic-icon";
                    icon.setAttribute("aria-hidden", "true");
                    // U+1F4CE PAPERCLIP -- the same glyph
                    // shared/_attachment_strip.html.erb emits as the HTML
                    // entity &#128206;. A literal character here, not an
                    // entity: textContent does not parse entities, so
                    // "&#128206;" as a string would show up on screen as
                    // that literal text instead of the glyph.
                    icon.textContent = "📎";

                    var filenameSpan = document.createElement("span");
                    filenameSpan.className = "attachment-generic-filename";
                    filenameSpan.textContent = attachment.alt;

                    link.appendChild(icon);
                    link.appendChild(filenameSpan);
                }

                strip.appendChild(link);
            }

            fieldset.appendChild(strip);
        }

        $hintsContainer.append(fieldset);

        // The playbar shows the newest hint so a stuck player does not have to
        // scroll for it. Guarded: this element only exists on the play screen,
        // and the poller must keep working if it is ever absent.
        var pinnedText = document.getElementById("PlaybarHintText");
        if (pinnedText) {
            pinnedText.textContent = hintText;
            var pinnedWrap = document.getElementById("PlaybarHint");
            if (pinnedWrap) { pinnedWrap.removeAttribute("hidden"); }
        }
    }

    ,loadHint = function() {
        hideCountdownContainer();
        showLoadIndicator();

        $.ajax({
            url: '/play/' + gameId + '/tip'
            ,
            method: 'GET'
            ,
            dataType: 'json'
            ,
            success: function(data) {
                hideLoadIndicator();
                showCountdownContainer();

                if ( data.hint_text ) {
                    appendHint(data.hint_num, data.hint_text, data.hint_label, data.attachments, data.attachments_label);
                }

                if ( !data.next_available_in ) {
                    $countdownContainer.text('Подсказок больше не будет');
                } else {
                    start(data.next_available_in);
                }
            }
        });
    }

    return {
        setup: function(config) {
            $(document).ready(function() {
                $hintsContainer = $('#LevelHintsContainer');
                $countdownContainer = $('#LevelHintCountdownContainer');
                $countdownTimerText = $('#LevelHintCountdownTimerText');
                $loadingIndicator = $('#LevelHintCountdownLoadIndicator');

                gameId = config.gameId;
                start(config.initialCountdownValue);
            });
        }
    };
}();
