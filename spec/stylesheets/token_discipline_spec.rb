require "rails_helper"

# The 2026-09-30 foundations work snapped 19 font-size declarations onto one
# scale and named the stacking layers. This keeps it that way: a raw value in
# any of these four files is a step back to fourteen ad-hoc sizes.
#
# tokens.css is where the raw values live, so it is not checked. calendar.css
# and jquery.autocomplete.css are legacy widgets the next wave item deletes.
describe "stylesheet token discipline" do
  # Constants in a describe body land on Object, so the names are specific.
  TOKEN_DISCIPLINE_FILES = %w[base.css components.css layout.css screens.css].freeze

  # CSS variables do not work inside @media, so the breakpoints cannot be
  # tokens; this list is the token. See the header comment in tokens.css.
  TOKEN_DISCIPLINE_MEDIA_WIDTHS = [
    "min-width: 48rem", "max-width: 47.99rem", "min-width: 52rem", "min-width: 60rem"
  ].freeze

  # Comments are blanked rather than deleted so reported line numbers still
  # match the file. Several comments mention "z-index 40" in prose.
  def declarations(file)
    css = Rails.root.join("public/stylesheets", file).read
    css = css.gsub(%r{/\*.*?\*/}m) { |c| c.gsub(/[^\n]/, " ") }
    css.lines.each_with_index.map { |line, i| [i + 1, line] }
  end

  def offenders(pattern, &allowed)
    TOKEN_DISCIPLINE_FILES.flat_map do |file|
      declarations(file).filter_map do |number, line|
        line.scan(pattern).flatten.reject(&allowed).map { |value| "#{file}:#{number}: #{value.strip}" }
      end.flatten
    end
  end

  it "takes every font-size from the type scale" do
    bad = offenders(/font-size:\s*([^;]+);/) { |v| v.strip.match?(/\Avar\(--text-[a-z0-9]+\)\z/) || v.strip == "inherit" }
    expect(bad).to be_empty, "raw font-size, use a --text-* token:\n#{bad.join("\n")}"
  end

  it "uses only the documented breakpoints" do
    bad = offenders(/@media[^{]*\(((?:min|max)-width:[^)]+)\)/) { |v| TOKEN_DISCIPLINE_MEDIA_WIDTHS.include?(v.strip) }
    expect(bad).to be_empty, "undocumented breakpoint:\n#{bad.join("\n")}"
  end

  it "takes every z-index from a layer token" do
    bad = offenders(/z-index:\s*([^;]+);/) { |v| v.strip.match?(/\Avar\(--z-[a-z]+\)\z/) }
    expect(bad).to be_empty, "raw z-index, use a --z-* token:\n#{bad.join("\n")}"
  end
end
