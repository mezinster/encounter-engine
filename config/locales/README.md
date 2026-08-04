# Locale notes

`Question#matches_any_answer` and `Level#find_question_by_answer` use
`String#upcase`, which is locale-independent. Turkish and Azeri are the known
exception: dotless `ı` uppercases to `I` rather than `İ`. If either locale is
ever added, those methods need `upcase(:turkic)` selected from the game's
locale, not the viewer's — this is a known limitation to be addressed when
that need arises, not something to solve now.
