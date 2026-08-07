require "rails_helper"

# app/views/invitations/new.html.erb used to interpolate nickname and email
# directly into a JS string literal. ERB's html_escape does not escape "\",
# so a nickname ending in a backslash escaped the closing quote and merged
# the two literals, putting the email value in executable position.
describe "the invitation autocomplete payload", type: :request do
  let(:captain) { create_user }
  let(:team)    { create_team(:captain => captain) }

  before do
    captain.update!(:team => team)
    put login_path, :params => { :email => captain.email, :password => "1234" }
  end

  it "does not let a backslash nickname break out of the emitted payload" do
    hostile = create_user
    hostile.update!(:nickname => "evil\\")

    get new_invitation_path

    expect(response).to have_http_status(:ok)
    # The breakout signature: a backslash immediately before a closing quote
    # inside the script block.
    expect(response.body).not_to include("evil\\'")
    expect(response.body).not_to include("data.push(")
    # JSON escapes it as a doubled backslash, which no JS parser treats as
    # a quote escape.
    expect(response.body).to include('"evil\\\\"')
    # The two assertions above prove the nickname appears in escaped form
    # somewhere, not that it appears ONLY in escaped form -- a reintroduced
    # interpolation using a different builder (e.g. double-quoted JS string
    # literals instead of "data.push(") would still pass both. Pin the
    # property instead: "evil" followed by any run of backslashes must
    # occur exactly once in the whole body, and that one run must be the
    # doubled backslash JSON produces, not the single backslash the
    # original nickname (and the old vulnerable code) would emit raw.
    expect(response.body.scan(/evil\\*/)).to eq(["evil\\\\"])
  end

  # The JSON island's protection against a "</script>" breakout rests
  # entirely on Rails' escape_html_entities_in_json (on by default, but
  # nothing pins it) plus the "raw" call that emits the JSON unescaped by
  # ERB. User#nickname only validates presence and uniqueness (see
  # app/models/user.rb), so a nickname containing literal markup is
  # registrable. If escape_html_entities_in_json were ever off, or to_json
  # were swapped for a JSON encoder that does not honor it (JSON.generate /
  # JSON.dump do not), the nickname's "</script>" would close the JSON
  # island's own <script> tag early and the following "<script>alert(1)
  # </script>" would run as markup.
  it "does not let a script-closing nickname break out of the JSON island" do
    hostile_nickname = "</script><script>alert(1)</script>"
    hostile = create_user
    hostile.update!(:nickname => hostile_nickname)

    get new_invitation_path
    malicious_body = response.body

    # Re-render the same page shape with a harmless nickname in the same
    # slot, so the comparison below isn't tied to how many <script> tags
    # this template happens to emit elsewhere (layout scripts, the behavior
    # block, etc.) -- only to whether THIS nickname added one of its own.
    hostile.update!(:nickname => "harmless-#{hostile.id}")
    get new_invitation_path
    baseline_body = response.body

    expect(response).to have_http_status(:ok)
    # escape_html_entities_in_json rewrites "<" as the six characters
    # backslash-u-0-0-3-c inside the JSON string, so the raw breakout text
    # never appears in the response verbatim -- only its escaped form does.
    expect(malicious_body).not_to include(hostile_nickname)
    # Built via concatenation, not a literal '<...' string, so nothing
    # in this spec file risks being misread as an actual "<" by an editor
    # or a future edit -- these are the six literal characters
    # backslash-u-0-0-3-c, exactly as escape_html_entities_in_json writes
    # them into the response body.
    lt = '\u' + '003c'
    gt = '\u' + '003e'
    escaped_breakout = "#{lt}/script#{gt}#{lt}script#{gt}alert(1)#{lt}/script#{gt}"
    expect(malicious_body).to include(escaped_breakout)
    # The real property: the hostile nickname must not add a closing
    # </script> tag of its own. If escaping of "<" were ever lost, this
    # nickname would inject two extra literal "</script>" occurrences
    # (closing the island's script tag early, and its own trailing one).
    expect(malicious_body.scan("</script>").length).to eq(baseline_body.scan("</script>").length)
  end

  it "does not emit any user's email address" do
    other = create_user

    get new_invitation_path

    expect(response.body).not_to include(other.email)
    expect(response.body).not_to include(captain.email)
  end

  it "still offers the other users' nicknames" do
    other = create_user

    get new_invitation_path

    expect(response.body).to include('id="invitation-nicknames"')
    expect(response.body).to include(other.nickname)
  end

  # jquery.autocomplete.js:671 renders each suggestion with .html(). Correct
  # JSON encoding (Task 1) delivers a real "<" to that sink, so formatItem
  # must escape. Before the JSON island, ERB's entity-encoding happened to
  # neutralise this -- an accident, not a control.
  it "escapes suggestion markup before the plugin renders it" do
    create_user.update!(:nickname => "<img src=x onerror=alert(1)>")

    get new_invitation_path

    # A single assertion binding formatItem's body to escapeHtml, not two
    # independent substring checks -- "escapeHtml" alone matches the helper's
    # declaration regardless of whether formatItem calls it, and
    # "formatItem:" alone matches the declaration line regardless of what the
    # body does (e.g. a regression that quietly changes the body to
    # `return row[0];` while leaving the declaration, helper and comment
    # untouched passes both). This regex only matches if the call is actually
    # inside formatItem's body. Verified by mutation: see task-2-report.md.
    expect(response.body).to match(/formatItem:\s*function\(row\)\s*\{\s*return escapeHtml\(row\[0\]\)/)
    # The raw nickname reaches the browser inside the JSON island (correct --
    # JSON.parse yields a string, not markup), but must never appear as live
    # markup outside it.
    expect(response.body).not_to include("<img src=x onerror=alert(1)>")
  end
end
