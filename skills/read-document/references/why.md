# Why it is read this way

The procedure is in `SKILL.md`.

## The gotchas, with their why

- **The plain-text extractor fails silently with scans.** It returns an empty
  file and exit code zero, so an agent in a hurry concludes "the document says
  nothing" and carries on. The reference tool, by contrast, fails with a non-zero
  code and explains that OCR is needed. It is the main reason to prefer it.
- **A file can be genuinely empty and not be the conversion's fault.** Before
  accusing the tool, look inside: presentations exported by some suites come out
  with no slides at all. Check the original before looking for another tool.
- **The first run downloads the package.** Count a few seconds and a few
  megabytes the first time; afterwards it stays cached.
- **CSV has no signature that identifies it.** If the content arrives via
  standard input, or the name does not end in `.csv`, the format has to be
  declared by hand.
- **Text formats are processed locally.** OCR of scans is not: that is a paid
  service from the vendor. Do not assume it is available.
