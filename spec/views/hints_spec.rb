# -*- encoding : utf-8 -*-
require "rails_helper"

# Task 9c: real ERB compilation for the 3 hints/* templates (hints/_list,
# hints/edit, hints/new). hints/_form.html.erb is a shared partial exercised
# indirectly through edit/new, since it now receives the form builder `f` as
# an explicit local (Merb's merb-helpers form fields read the "current form"
# implicitly; Rails' don't, so the builder has to be passed through render).
RSpec.describe "hints/_list", type: :view do
  it "shows the empty message when the level has no hints" do
    level = create_level

    assign(:level, level)

    render partial: "hints/list", locals: { hints: [] }

    expect(rendered).to include(I18n.t("hints.list.empty"))
  end

  it "shows edit/delete links for each hint while the game hasn't started" do
    level = create_level
    hint = create_hint(level: level, delay: 300)

    assign(:level, level)

    render partial: "hints/list", locals: { hints: [hint] }

    expect(rendered).to include(hint.text)
    expect(rendered).to include(I18n.t("hints.list.after"))
    expect(rendered).to include(I18n.t("hints.list.minutes_colon"))
    expect(rendered).to include(edit_game_level_hint_path(level.game, level, hint))
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("shared.edit_short")))
    expect(rendered).to include(delete_game_level_hint_path(level.game, level, hint))
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("shared.delete_short")))
  end
end

RSpec.describe "hints/edit", type: :view do
  it "renders the edit-hint form via the shared _form partial" do
    level = create_level
    hint = create_hint(level: level)

    assign(:game, level.game)
    assign(:level, level)
    assign(:hint, hint)

    render

    expect(rendered).to include(I18n.t("hints.edit.heading_prefix"))
    expect(rendered).to include(level.name)
    expect(rendered).to include(level.game.name)
    expect(rendered).to include(I18n.t("hints.form.text_label"))
    expect(rendered).to include(I18n.t("hints.form.delay_label"))
    expect(rendered).to include(I18n.t("hints.form.minutes_suffix"))
    expect(rendered).to include(I18n.t("hints.edit.submit"))
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("shared.cancel")))
    expect(rendered).to include(game_level_hint_path(level.game, level, hint))
  end
end

RSpec.describe "hints/new", type: :view do
  it "renders the new-hint form via the shared _form partial" do
    level = create_level
    hint = Hint.new(level: level)

    assign(:game, level.game)
    assign(:level, level)
    assign(:hint, hint)

    render

    expect(rendered).to include(I18n.t("hints.new.heading_prefix"))
    expect(rendered).to include(I18n.t("hints.form.text_label"))
    expect(rendered).to include(I18n.t("hints.form.delay_label"))
    expect(rendered).to include(I18n.t("hints.new.submit"))
    expect(rendered).to include(game_level_hints_path(level.game, level))
    expect(rendered).to include(ERB::Util.html_escape(I18n.t("shared.cancel")))
  end
end
