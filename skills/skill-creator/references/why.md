# Why skills are written this way

The procedure is in `SKILL.md`. Here are the reasons and what was measured.

## Why size matters

Each skill is loaded in full into the agent's context every time it is used, and
a full context performs worse and costs more. Measured on 28-09-2026 with a
fixed prompt and the model's tokenizer:

| Skill | Before | Shortened | Saving |
| ----- | ------ | --------- | ------ |
| `ship` | 2,821 tokens | 1,533 | 46 % |
| `flow` | 3,334 | 1,390 | 58 % |
| `review-pr` | 3,473 | 1,890 | 45 % |
| `x-posts` | 4,146 | 1,897 | 54 % |
| `share-local` | 2,850 | 1,480 | 48 % |
| `visual-test` | 2,619 | 1,300 | 51 % |

Almost half of each skill was explanation of why each rule existed. With three
scenarios of known answer, the short versions answered like the originals, once
two nuances that the first draft had lost were corrected.

Translating into English saved less: `ship` went from 2,821 to 2,203 tokens
(22 %). In Spanish, each word takes on average almost twice as many tokens, so
1,000 words are about 1,900 tokens.

## Why test with scenarios

The two mistakes that came up when shortening:

- `review-pr` lost what counts as "text only", and the first draft allowed
  merging a CSS change without asking, which the script treats as code.
- `visual-test` allowed accepting a page with only `audit` and `checks`, without
  looking at the screenshots.

Neither was visible when reading: the short text seemed complete. They were seen
when comparing the answers of the two versions to the same question. That is why
the nuance that changes a decision goes in `SKILL.md`, not in the reference: the
reference is only opened if the agent doubts, and when it loses a nuance it does
not doubt.

## Why search before creating

Two skills that answer the same sentence take each other's activation away, and
the agent ends up choosing the worse one. Extending an existing one keeps the
catalogue short, which is also context: the agent sees one line of each skill in
every session.

## Why the description rules

It is the only thing the agent reads before deciding. A skill that does not
activate when it should is as if it did not exist. Symptoms are written the way
whoever has the problem would say them, because that person does not yet know
they need this skill.

"When not to use" avoids applying an expensive procedure to a trivial case.

## Why gotchas are worth more

Anyone can deduce the happy procedure. What cannot be deduced is that a certain
manufacturer layer blocks touches, that without cancelling the animations the
output comes out blank, or that the media variant overrides the base class.

## Why the adapter has to discriminate

The adapter and the procedure it adapts share vocabulary, and that is
unavoidable. The problem is when the adapter also wins the sentences without
proper names: the catalogue is common to all projects and it then wins where it
does not apply. The two sentences are written before the description, the way
the job would really be asked for; taking them from the already-written
description makes the test always pass.

## Why execute it

Written from memory it always lacks a step: the ones you took for granted only
show up when following it to the letter.
