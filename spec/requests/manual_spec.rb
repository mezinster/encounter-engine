require "rails_helper"
require "tmpdir"
require "fileutils"

describe "the manual", type: :request do
  it "serves the Russian manual to a signed-out visitor" do
    get manual_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Руководство пользователя")
  end

  it "serves the English manual when the locale is en" do
    get manual_path(:locale => :en)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("User manual")
  end

  it "renders the markdown rather than echoing it" do
    get manual_path

    expect(response.body).to include("<table>")
    expect(response.body).not_to include("|---|")
  end

  # The literal Polish, not I18n.t: an assertion written as
  # include(I18n.t(key)) resolves the same way the view does and therefore
  # cannot fail on a missing or wrong key.
  # Driven against a directory holding only ru.md rather than against a locale
  # that happens to lack a manual: every registered locale has one now, so the
  # note would otherwise be untestable end to end -- and it is precisely the
  # thing a reader sees when a translation is missing, which will happen again
  # the next time a locale is registered ahead of being translated.
  it "tells a reader whose language has no manual that this is the Russian one" do
    Dir.mktmpdir do |only_russian|
      FileUtils.cp(Rails.root.join("docs/manual/ru.md"), File.join(only_russian, "ru.md"))
      stub_const("Manual::Source::DIRECTORY", Pathname.new(only_russian))

      get manual_path(:locale => :pl)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Podręcznik nie został jeszcze przetłumaczony")
      expect(response.body).to include("Руководство пользователя")
    end
  end

  it "shows a reader with a translated manual their own language, and no note" do
    get manual_path(:locale => :pl)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Podręcznik nie został jeszcze przetłumaczony")
  end

  it "shows no fallback note when the manual is in the reader's language" do
    get manual_path(:locale => :en)

    expect(response.body).not_to include("not yet available in your language")
  end

  it "shows no fallback note for ru either" do
    get manual_path(:locale => :ru)

    expect(response.body).not_to include("Руководство пока не переведено")
  end

  # Ties renderer, controller, route and real content together in one
  # request: ru.md contains a link to `](en.md)`, and this is the only spec
  # that checks the link pass actually survives all the way into the bytes a
  # browser receives, rather than into an intermediate Nokogiri fragment.
  it "rewrites the link to the other language's manual into the app's own route" do
    get manual_path

    expect(response.body).to include(%(href="/manual?locale=en"))
  end

  it "is linked from the left menu signed out" do
    get root_path

    expect(response.body).to include(%(href="/manual"))
  end

  it "is linked from the left menu signed in" do
    user = create_user
    put login_path, :params => { :email => user.email, :password => "1234" }

    get dashboard_path

    expect(response.body).to include(%(href="/manual"))
  end
end
