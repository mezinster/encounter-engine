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

    ,appendHint = function(hintNum, hintText) {
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
        legend.textContent = "Подсказка #" + hintNum;

        fieldset.appendChild(legend);
        fieldset.appendChild(document.createTextNode(hintText));

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
                    appendHint(data.hint_num, data.hint_text);
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
