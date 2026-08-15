# -*- encoding : utf-8 -*-
require "rails_helper"

# Game descriptions, level texts and hints are author-written free text. They
# never go through t() (see the i18n note in CLAUDE.md) and are rendered
# verbatim -- so HTML folds any line break the author typed, and a text
# deliberately laid out in paragraphs arrives as one wall of prose.
#
# with_newlines restores the break WITHOUT widening the content model. That
# distinction is what the escaping examples below exist to pin: Rails'
# simple_format would have solved the same problem by running sanitize, which
# PERMITS a tag whitelist through, quietly turning these fields from plain
# text into limited HTML.
describe ApplicationHelper, :type => :helper do
  describe "#with_newlines" do
    it "turns a newline into a break" do
      helper.with_newlines("first\nsecond").should == "first<br>second"
    end

    # The property that makes this change safe to land on every existing game:
    # text with no newline in it produces exactly what <%= %> produced before.
    it "leaves single-line text byte-identical" do
      helper.with_newlines("just one line").should == "just one line"
    end

    it "keeps a blank line as two breaks" do
      helper.with_newlines("one\n\ntwo").should == "one<br><br>two"
    end

    # A browser submits textarea content with CRLF line endings, so splitting
    # on "\n" alone leaves a stray \r ending every line.
    it "handles CRLF without leaving a carriage return behind" do
      helper.with_newlines("first\r\nsecond").should == "first<br>second"
      helper.with_newlines("first\r\nsecond").should_not include("\r")
    end

    it "renders nil as empty" do
      helper.with_newlines(nil).should == ""
    end

    it "drops trailing newlines rather than emitting dangling breaks" do
      helper.with_newlines("text\n\n").should == "text"
    end

    # The one that matters. An author is a registered user, not a trusted
    # party: anyone can create a game.
    it "escapes HTML in the text" do
      result = helper.with_newlines("<script>alert(1)</script>")

      result.should_not include("<script>")
      result.should include("&lt;script&gt;")
    end

    it "escapes HTML on every line, not just the first" do
      result = helper.with_newlines("safe\n<img src=x onerror=alert(1)>")

      result.should_not include("<img")
      result.should include("&lt;img")
    end

    # safe_join marks its result html_safe, so an input already flagged safe
    # must still be escaped -- otherwise a value that reached the helper
    # pre-marked would pass straight through.
    it "escapes even a string already marked html_safe" do
      result = helper.with_newlines("<b>bold</b>".html_safe)

      result.should_not include("<b>")
      result.should include("&lt;b&gt;")
    end

    it "returns an html_safe string so the view does not double-escape it" do
      helper.with_newlines("a\nb").should be_html_safe
    end
  end
end
