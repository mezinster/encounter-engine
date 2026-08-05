require "rails_helper"

describe "content locale resolution", type: :request do
  let(:author) { create_user }
  # A draft, not a published game: the publish gate (Task 3) blocks a
  # non-draft game whose declared locales aren't fully translated, and this
  # spec only cares about locale resolution, not translation completeness.
  let(:game) do
    g = create_game(:author => author, :is_draft => true)
    g.available_locale_list = %w[ru en]
    g.save!
    g
  end

  it "uses the game's primary locale for an anonymous visitor" do
    expect(controller_content_locale_for(game)).to eq("ru")
  end

  it "uses the user's own locale when the game offers it" do
    user = create_user
    user.update!(:locale => "en")
    expect(controller_content_locale_for(game, :user => user)).to eq("en")
  end

  # A Georgian speaker browsing a Russian-only game reads Russian content
  # inside Georgian chrome. The two locales are independent by design.
  it "falls through to the primary locale when the game does not offer the user's" do
    user = create_user
    user.update!(:locale => "ka")
    expect(controller_content_locale_for(game, :user => user)).to eq("ru")
  end

  it "prefers a stored per-game override over the user's locale" do
    user = create_user
    user.update!(:locale => "ru")
    GameLocalePreference.create!(:user => user, :game => game, :locale => "en")
    expect(controller_content_locale_for(game, :user => user)).to eq("en")
  end

  it "ignores an override for a locale the game no longer offers" do
    user = create_user
    user.update!(:locale => "ru")
    GameLocalePreference.create!(:user => user, :game => game, :locale => "ka")
    expect(controller_content_locale_for(game, :user => user)).to eq("ru")
  end

  it "follows an explicit ?locale= for a signed-in user, as it already does for a guest" do
    user = create_user
    user.update!(:locale => "ru")
    # LocaleSelection resolves ?locale=en into I18n.locale before the action runs.
    result = I18n.with_locale(:en) do
      controller = ApplicationController.new
      controller.define_singleton_method(:current_user) { user }
      controller.send(:content_locale_for, game)
    end
    expect(result).to eq("en")
  end

  # Helper: exercises the concern through a real controller instance so the
  # precedence is tested where it actually runs. A real request runs
  # LocaleSelection#set_locale first, which resolves the user's stored locale
  # (or ?locale=) into I18n.locale and wraps the action in I18n.with_locale.
  # This harness reproduces that, rather than testing a path no request takes.
  def controller_content_locale_for(game, user: nil)
    controller = ApplicationController.new
    controller.define_singleton_method(:current_user) { user }
    chrome_locale = user&.locale.presence || I18n.default_locale
    I18n.with_locale(chrome_locale) { controller.send(:content_locale_for, game) }
  end
end
