---
name: read-document
description: Bring into context a document that cannot be opened directly —a Word, a PowerPoint, an Excel, an ODF, an EPUB or a long PDF— by converting it to Markdown, choosing the right route by type and checking that the output is not empty. Use when an office attachment arrives, when a presentation or a spreadsheet has to be read, when a PDF is too long to read whole, or when someone says "mira este documento", "resume este informe" or "qué dice el adjunto".
---

# read-document

A document that cannot be opened is a document that does not exist. This skill
converts it to Markdown so it can be read, quoted and returned to.

The conversion command is one line. What this skill contributes are three
decisions: **which route**, **how to know it went well** and **what was lost
along the way**.

## When to use

- An attachment arrives as `.docx`, `.pptx`, `.xlsx`, `.odt`, `.odp`, `.ods`,
  `.rtf`, `.epub` or `.csv`. Without conversion there is no way to read them.
- A PDF is long or full of data and the content is needed, not the layout.
- A fragment of a document has to be quoted literally in the answer or in the
  code.

## When not to use

- **A PDF judged by how it looks**: a laid-out report, a design, an invoice
  whose layout matters. Open it directly, which preserves the layout.
  Converting it throws away exactly what has to be looked at.
- **A document from which only a single known piece of data is needed** that can
  be searched for with a text tool.
- **Extracting structured fields to JSON**. This delivers Markdown; the
  extraction work is later and different.
- **A scan or a photographed document.** There is no text to extract here: OCR
  is needed, which is something else. See step 3.

## 1. Choose the route

| Input | Route | Why |
| --- | --- | --- |
| Office (Word, PowerPoint, Excel, ODF, RTF, EPUB, CSV) | Convert to Markdown | No alternative: the file is a ZIP of XML |
| PDF with text, long or data-heavy | Convert to Markdown | Comes out with the tables already structured and takes up much less than the flat dump |
| Layout or visual PDF | Open it directly, without converting | Conversion throws away the layout, which is what is being judged |
| Scanned or photographed PDF | None: stop and say so | Without a text layer there is nothing to extract |

## 2. Convert

The reference tool is `anydoc`: a binary that reads the fourteen formats and
emits Markdown with a single serialiser, so the output is consistent wherever
it comes from. MIT licence, no credentials, no external service for the text
formats.

```bash
npx -y @firecrawl/anydoc <file> -o <destination>.md
```

Save the result in a temporary file instead of leaving it only in the
conversation: it lets you quote it, search inside it and not reconvert on every
round.

If the tool is not available, there is a plan B depending on the format, with
losses:

- PDF: the system text extractor, with the layout preserved. It comes out much
  longer and without table structure.
- Office: the office suite in headless mode converts to HTML or text. **It
  cannot convert presentations to text**: for them you have to go through PDF
  first, and then the order and the notes are lost.

## 3. Check that something came out

**This is the step that avoids the expensive failure**, and it is not optional.

```bash
wc -c <destination>.md
```

Compare the size with what the document would be expected to yield. A document
of several pages that produces four lines indicates a failed conversion.

If the tool warns that OCR is needed, **stop and say so**. Do not carry on with
half a conversion or claim that the document is empty. The document has content;
what fails is the reading route. Offer the real ways out —ask for the original
in another format, or use an OCR service— and leave the decision to whoever is
asking.

## 4. Say what was lost

Before working on the Markdown, check whether the conversion swallowed something
that will be needed later, and say so:

- **Presentations lose the separation between slides.** The text comes out in one
  run, with no mark of where each one starts. If later you have to quote "slide
  4", that reference no longer exists.
- **Complex PDF tables come out misaligned.** Merged cells and multi-level
  headers are rebuilt badly: the columns dance. It is good for reading, not for
  copying figures blindly.
- **Images, charts and colour disappear.** If the document's argument is in a
  chart, nothing of it remains in the Markdown.

## Gotchas

- **The plain-text extractor fails silently with scans** (empty file and code
  0); `anydoc` fails with a non-zero code and warns about OCR.
- **A file can be genuinely empty:** look at the original before blaming the
  tool.
- **The first run downloads the package;** afterwards it stays cached.
- **A CSV without the `.csv` extension** or via standard input has to be
  declared.
- **OCR of scans is a paid service;** do not assume it is available.

## Anti-patterns

- **Converting a PDF that had to be looked at.** If what is judged is the
  layout, conversion destroys the question.
- **Summarising without checking the output size.** A summary of an empty
  conversion is an invention in the shape of an answer.
- **Quoting the slide or the page after converting.** Those references do not
  survive into Markdown; if they are needed, go back to the original.
- **Reconverting on every round.** Save the Markdown and work on it.

## Related

- `/render-loop` — the opposite direction: iterate on a rendered output
- `/visual-diff` — when what has to be compared is how it looks, not what it says
