# language: en
#
# The other 58 feature files are Russian: the original Merb app only ever
# spoke Russian, so its behavioural contract is written in Russian, and that
# contract is read-only (see the header of features/support/env.rb and
# task-12-report.md). This one is new platform behaviour with no Russian
# original to be faithful to, so it is written in the language it actually
# describes: an English-language reader choosing English.

Feature: Choosing an interface language
  A platform serving several cities must let each player read the interface
  in their own language, without altering the games themselves. Game names,
  level and hint text, team names, nicknames and answer codes are written by
  organisers and players, not by the platform, and are never translated --
  only the surrounding chrome (menus, labels, buttons) is.

  Background:
    Given a user "Iv" is registered

  Scenario: A visitor switches the interface to English
    When I go to the front page with locale "en"
    Then I should see "Log in"

  Scenario: A signed-in user saves a language preference
    Given I am logged in as "Iv"
    When I set my interface language to "en"
    And I go to the dashboard
    Then I should see "My games"

  Scenario: Game content is not translated
    Given a game "Котлованы Бишкека" was created by "Iv"
    When I go to the games list with locale "en"
    Then I should see "Котлованы Бишкека"

  Scenario: The switcher link preserves other query parameters when it replaces locale
    When I go to the front page with locale "ru" and extra query "utm_source=email"
    And I click the "English" language switcher link
    Then I should see "Log in"
    And the page URL should still include "utm_source=email"
