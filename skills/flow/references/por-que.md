# Why the cycle works this way

The procedure is in `SKILL.md`. Here is the reason for each step, for when you
need to decide whether skipping one makes sense.

## Isolate before starting

It is what avoids the most expensive problem of working with several agents: two
sessions on the same directory trample each other's files, mix their changes in
the same commit and fight over the port and the database. The branch is born
separate and is the same one that ends up being the proposal, so the work comes
out as something to be reviewed and not as loose changes mixed with someone
else's.

Isolating after starting forces you to move changes between branches, which is
exactly the mess you wanted to avoid.

## Ask and plan before the code

A round of questions is cheaper than a diff built on an assumption. A plan that
says "I am going to change the cache key format" is rejected in five seconds;
the same mistake discovered later is a diff to review and probably revert.

## Tests and debugging during, not at the end

Tests written afterwards are written so that they pass. Changing things to see
whether they work is what turns one bug into two.

## Show before proposing

It goes after `/ship` so that what is shown is exactly what is going to be
proposed, and before `finish` because proposing already means showing the work
to others.

## Propose and wait for the CI

`finish` refuses without a commit or without the gate because what is not in git
does not reach the review, and this way no code proposal that nobody has
reviewed gets opened.

Waiting for the CI in front of the screen blocks the session for minutes in
which nobody advances. The rigour lies in not accepting the proposal until the
result is seen, and that is fulfilled just the same by looking at it later. The
limit of three attempts exists because continuing to push blind fixes leaves a
branch with ten "fix ci" commits: if on the third it is still red, the problem
was not the one it seemed.

## Review from another context

`/ship` asks whether what you did is ready; `/review-pr` asks whether what is
being proposed is correct and complete, and it is asked by someone who was not
inside the problem. It is the difference between reviewing and confirming.

## Merge and watch

The decision to merge belongs to a person; the command only makes sure it
arrives informed. "Nothing blocks it" is not the same as "it is verified". If
the deployment is not watched, the first to see the failure is a user.

## Close

What was learned that does not stay in the code is lost with the session, and in
three months someone discovers it again.

## What you pay for skipping each step

| Step | If you skip it |
| ---- | -------------- |
| Understand | You write code to find out what the documentation already says |
| Isolate | You get mixed up with another session and resolve conflicts that did not exist |
| Ask | You build well what was not wanted, and it shows when you present it |
| Plan | You discover the error when it is already a diff |
| Tests during | You write them to pass, not to fail |
| The gate | Broken work gets in, and is discovered in production |
| Show | What is proposed has not been seen by whoever decides |
| Propose | The change is not reviewed, or is reviewed once already integrated |
| Wait for CI | The red is discovered when going to merge, without context |
| Merge | It gets in without looking at the CI or the conflicts |
| Watch the deployment | The first to see the failure is a user |
| Close | What was learned dies with the session |
