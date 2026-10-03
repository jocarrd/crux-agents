---
name: redaccion
description: Write and review texts that do not read as model-generated. Gives the concrete list of markers that give away an AI text —rule of three, negative parallelism, em dash, epigrams, recurring vocabulary, grandiloquence—, a script that counts them on the real text, and the method for rewriting without falling into them. Use when writing any text another person will read: documentation, presentations, commit messages, emails, proposals and interface copy. And always before delivering a document to a client.
---

# redaccion

A generated text is recognised by its shape before its content. The markers are
few, concrete and counted with a script. More examples and the reason behind
each rule: `<this-skill-directory>/references/por-que.md`.

**When:** before delivering a text to an outsider; when writing documentation, a
presentation, a proposal or a long email; when someone says a text "suena a IA".

The skill's target is **Spanish text**: the examples, patterns and word lists
below are Spanish on purpose, because they are the data it looks for.

## The seven markers

The first three are enough to recognise a generated text.

1. **Negative parallelism.** «No es X, es Y», «X, no Y», «no se trata de X, sino
   de Y». → Drop the negation and keep what you assert: «Un plan sirve para que
   alguien lo pare a tiempo».
2. **Rule of three.** Three adjectives or phrases where the content called for
   one or two («claro, sencillo y directo»). → If the third adds nothing, it is
   surplus.
3. **Epigram as headline.** «Lo que toda pieza tiene que cumplir» instead of
   «Requisitos». → The standard term of the trade.
4. **Excess em dashes**, where a comma, a parenthesis or a full stop belonged. →
   One or two per document.
5. **Aphoristic colons** to finish with a maxim («El resultado es claro: no
   funciona»). → Full stop, or a single assertion.
6. **Recurring vocabulary:** clave, fundamental, crucial, robusto, sólido,
   potente, riguroso, profundizar, panorama, enfoque, en última instancia, cabe
   destacar, es importante señalar, no solo… sino también, permite (as a
   catch-all), garantizar, optimizar, impulsar. → The concrete verb or noun:
   «permite mejorar la legibilidad» → «se lee mejor».
7. **Grandiloquence:** linking something to a bigger theme or closing with a
   reflection that has no data («Esto es lo que separa un dato de una
   afirmación»). → Delete it.

## How to review

```bash
node <this-skill-directory>/scripts/redaccion.mjs check <file…>      # counts (revisar still works)
node <this-skill-directory>/scripts/redaccion.mjs check --text "…"   # one string
node <this-skill-directory>/scripts/redaccion.mjs detail <file>      # each case on its line
```

The script counts and locates; deciding whether each case is surplus is up to
you. Only markers 1, 2, 3, 6 and 7 score; the em dash and the colons are
reported separately, because a regular expression cannot tell a punchline from
an explanation.

**Indicative threshold** for about 2,000 words: zero negative parallelisms, fewer
than three rules of three, no epigrammatic headline.

## False positives the script already excludes

- «clave» as a noun (una clave SSH); it only counts as an adjective.
- «lo que hace falta», which contains «lo que hace».
- Colons that open an enumeration.

## What it does not fix

Register: a text can pass all seven and be useless because it uses jargon its
reader does not know. Before reviewing the form, ask yourself who reads it. And
do not take it to the extreme: a well-placed dash or an enumeration of three real
things is good writing.
