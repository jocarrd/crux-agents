#!/usr/bin/env bash
# crux prose: the markers of a model-generated text, in Spanish and English.

_prose() { "$CRUX_HOME/bin/crux" prose "$@"; }

test_prose_flags_a_generated_spanish_text() {
  sandbox >/dev/null
  cat > "$SB/es.md" <<'TXT'
# Lo que de verdad importa

No es una herramienta, es un sistema de trabajo. Es fundamental, robusto y sólido.
No se trata de velocidad, sino de confianza. Cabe destacar que garantiza resultados.
TXT
  local out rc=0
  out="$(_prose check "$SB/es.md" 2>&1)" || rc=$?
  assert_eq "1" "$rc" "a text full of markers exits 1"
  assert_contains "$out" "Spanish" "the language is detected"
  assert_contains "$out" "sounds like a machine" "and the verdict says so"
  out="$(_prose detail "$SB/es.md" 2>&1)" || true
  assert_contains "$out" "No es una herramienta, es" "detail shows each case"
  assert_contains "$out" "L3" "with the line it is on in the file"
}

test_prose_flags_a_generated_english_text() {
  sandbox >/dev/null
  local out rc=0
  out="$(_prose check --text "It's not a tool, it's a way of working. We leverage a robust, seamless platform to unlock value." 2>&1)" || rc=$?
  assert_eq "1" "$rc" "the English tics count too"
  assert_contains "$out" "English" "and the language is detected"
}

test_prose_lets_plain_text_through() {
  sandbox >/dev/null
  local out rc=0
  out="$(_prose check --text "The build takes four minutes. Run it before you push, and read the log if it fails." 2>&1)" || rc=$?
  assert_eq "0" "$rc" "a plain text passes"
  assert_contains "$out" "sounds human" "and says so"
}

test_prose_does_not_count_what_is_quoted_or_code() {
  sandbox >/dev/null
  cat > "$SB/lesson.md" <<'TXT'
Avoid «no es X, es Y» and "it's not X, it's Y" in titles.

```
It's not a tool, it's a way of working. Robust, seamless and holistic.
```

> No es una herramienta, es un sistema.
TXT
  local out rc=0
  out="$(_prose check "$SB/lesson.md" 2>&1)" || rc=$?
  assert_eq "0" "$rc" "a text that teaches the markers is not judged by its examples"
  assert_contains "$out" "load 0" "nothing is scored"
}

test_prose_takes_the_language_it_is_told() {
  sandbox >/dev/null
  local out
  out="$(_prose check --lang es --text "The plan is ready." 2>&1)" || true
  assert_contains "$out" "Spanish" "--lang wins over detection"
  local rc=0
  out="$(_prose check --lang fr --text "x" 2>&1)" || rc=$?
  assert_eq "1" "$rc" "an unknown language stops"
  assert_contains "$out" "es or en" "and says which there are"
}

test_prose_stops_on_a_file_it_cannot_read() {
  sandbox >/dev/null
  local out rc=0
  out="$(_prose check "$SB/missing.md" 2>&1)" || rc=$?
  assert_eq "1" "$rc" "a missing file is an error, not an empty text"
  assert_contains "$out" "cannot read" "and it is named"
}
