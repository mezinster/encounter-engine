#!/usr/bin/env bash
# PostToolUse hook: syntax-check Ruby files after Claude writes or edits them.
# Reads the tool payload on stdin, runs `ruby -c`, and reports parse errors.
# Exits 0 always — this reports, it does not block.

f=$(jq -r '.tool_input.file_path // .tool_response.filePath // empty')

case "$f" in
  *.rb) ;;
  *) exit 0 ;;
esac

[ -f "$f" ] || exit 0

# rbenv shims are not on PATH in non-login shells; prefer them, fall back to system ruby.
RUBY="$HOME/.rbenv/shims/ruby"
[ -x "$RUBY" ] || RUBY=ruby
command -v "$RUBY" >/dev/null 2>&1 || exit 0

if ! out=$("$RUBY" -c "$f" 2>&1); then
  printf '{"systemMessage":%s}' "$(printf '%s' "$out" | jq -Rs .)"
fi

exit 0
