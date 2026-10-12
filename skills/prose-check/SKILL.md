---
name: prose-check
description: Write and review texts, in Spanish or English, that do not read as model-generated. Gives the concrete markers that give away an AI text —negative parallelism, rule of three, epigrammatic headlines, em dashes, recurring vocabulary, grandiloquence—, a command that counts them on the real text, and the method for rewriting without falling into them. Use when writing any text another person will read: documentation, presentations, commit messages, emails, proposals, posts and interface copy, and always before delivering a document to a client. Also when someone says a text "suena a IA" or "sounds like AI". Formerly called redaccion.
---

# prose-check

A generated text is recognised by its shape before its content. The markers are
few, concrete and counted with a command. More examples and the reason behind
each rule: `<this-skill-directory>/references/why.md`.

**When:** before delivering a text to an outsider; when writing documentation, a
presentation, a proposal or a long email; when someone says a text "suena a IA".

It works on Spanish and English text. The examples below come in both languages
because they are the data it looks for.

## The seven markers

The first three are enough to recognise a generated text.

1. **Negative parallelism.** «No es X, es Y», «no se trata de X, sino de Y»;
   "it's not X, it's Y", "not just X, but Y". → Drop the negation and keep what
   you assert: «Un plan sirve para que alguien lo pare a tiempo».
2. **Rule of three.** Three adjectives or phrases where the content called for
   one or two («claro, sencillo y directo»; "fast, simple and reliable"). → If
   the third adds nothing, it is surplus.
3. **Epigram as headline.** «Lo que toda pieza tiene que cumplir» instead of
   «Requisitos»; "What makes a good test" instead of "Tests". → The standard
   term of the trade.
4. **Excess em dashes**, where a comma, a parenthesis or a full stop belonged. →
   One or two per document.
5. **Aphoristic colons** to finish with a maxim («El resultado es claro: no
   funciona»; "The answer is simple: measure it"). → Full stop, or a single
   assertion.
6. **Recurring vocabulary.** Spanish: «clave», «fundamental», «crucial»,
   «robusto», «sólido», «potente», «profundizar», «panorama», «cabe destacar»,
   «garantizar», «optimizar», «impulsar». English: "delve", "crucial",
   "pivotal", "robust", "seamless", "leverage", "landscape", "foster",
   "holistic", "unlock", "harness", "streamline", "it's worth noting". → The
   concrete verb or noun: «permite mejorar la legibilidad» → «se lee mejor»;
   "leverages caching to optimize" → "caches".
7. **Grandiloquence:** linking something to a bigger theme or closing with a
   reflection that has no data («Esto es lo que separa un dato de una
   afirmación»; "and that makes all the difference"). → Delete it.

## How to review

```bash
crux prose check <file…>                 # counts
crux prose check --text "…"              # one string
crux prose detail <file…>                # each case with its line
crux prose check --lang es <file>        # force the language; detected otherwise
```

The command counts and locates; deciding whether each case is surplus is up to
you. Markers 1, 2, 3, 6 and 7 score; the em dash and the colons are reported
apart, because a pattern cannot tell a punchline from an explanation. It exits 1
when the text reads as generated.

**Indicative threshold** for about 2,000 words: zero negative parallelisms, fewer
than three rules of three, no epigrammatic headline.

## What it leaves out on purpose

- Quotes, «quoted text», “quoted text” and code: a text that teaches what to
  avoid has it written out.
- «clave» as a noun (una clave SSH); it only counts as an adjective.
- «lo que hace falta», which contains «lo que hace».
- Colons that open an enumeration.

## What it does not fix

Register: a text can pass all seven and be useless because it uses jargon its
reader does not know. Before reviewing the form, ask yourself who reads it. And
do not take it to the extreme: a well-placed dash or an enumeration of three real
things is good writing.
