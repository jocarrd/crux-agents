# How X distributes reach, and why the rules are these

The procedure is in `SKILL.md`. Here is the data it rests on.

## The published algorithm

X published the code of its "For you" feed at `github.com/xai-org/x-algorithm`
and committed to updating it every four weeks. Before an important campaign,
check the repository: the weights change. What is stable is this:

- **The feed predicts actions and weighs them.** Each post receives the sum of
  "probability that you do X × weight of X": replying, sharing by message or by
  copying the link, quoting, reposting, liking, following the author, clicking
  and reading time, and also "not interested", muting, blocking and reporting.
- **Conversing weighs much more than a like.** In the weights published in
  August 2026, a reply is worth about 10 times a like. Sharing by copying the
  link, or a reply inside a conversation between accounts that follow each
  other, about 40. Following the author, about 8.
- **Negative signals weigh far more.** A report subtracts what hundreds of likes
  add, and muting or "not interested", dozens. A post that annoys a few sinks
  the reach for many.
- **Outside your followers you reach with a discount.** Posts from accounts you
  do not follow are multiplied by a factor below 1. Small accounts get a boost
  up to a certain impression threshold.
- **Posting often has diminishing returns.** Each post by the same author in a
  person's feed receives a decaying factor. Two good posts a day perform better
  than five in a row.
- **The shelf life is short.** Posts older than 48 hours drop out of the
  selection.
- **A link in the body reduces reach.** It does not appear as a rule in the
  code, but the 2026 measurements agree on a sharp drop, larger on accounts
  without Premium, because a click takes people off X.

## Why one post, one goal

If a post asks for several actions at once, it achieves none.

## Why the brand is built this way

A personal brand is built by showing the work, not by announcing it. Promotion
works when it comes after many posts that asked for nothing. Continuity makes
people follow you, because following you is the way not to miss the next
chapter. Opening with a situation or a person, and not with the product, is
what makes someone stop.

## Why the first line

It decides whether the rest is read. Hooks that promise without delivering
drive away the people you are looking for and count as markers of empty content.

## Why these writing rules

On mobile a six-line block gets skipped. Tagging people so they see it, when the
post is not about them, reads as spam and provokes silence. On X, a generated
text is given away above all by the em dash, enumerations of three, negative
parallelism and an announcement tone. Asking for empty engagement attracts
low-quality engagement and spam readings.

## Why the first hour

What happens right after publishing decides the rest. The author's reply inside
a conversation is one of the signals that weigh most. For a small account,
replying well is worth more than posting a lot.

## Sources

- X feed code: `github.com/xai-org/x-algorithm` (signals, scoring, author
  diversity, out-of-network discount, 48-hour window).
- Weights published in August 2026, summarised in explainx.ai ("X Discloses
  Ranking Weights").
- Measurements on links in the post body: Social Media Today, OpenTweet (2026).
- Public X skills reviewed: `sergebulaev/x-skills`,
  `alirezarezvani/claude-skills` (`x-twitter-growth`), `yamz8/x-thread-skill`.
- Build in public and personal brand: guides from Indie Hackers and Justin
  Welsh.
