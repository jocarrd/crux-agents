---
name: deploy-watch
description: Watch a deployment after merging until confirming the new version is in production and working: wait for it to arrive, check that routes respond without errors, look at what the change touched and say how to roll back if something fails. Use right after merging a proposal that deploys itself, when someone asks whether it is already in production, or when a deployment finished green and nobody has actually looked at the site.
---

# deploy-watch

Merging is not deploying, and a green deployment is not working. Between the two
there is a gap where nobody looks: CI says it built, the platform says it
published, and the first one to open the site is a user.

This closes that gap. It is the last step of the cycle before closing the
session.

## When it applies

- After merging a proposal whose deployment starts on its own.
- After a manual deployment (`/deploy-fallback`).

## When it doesn't

- Changes that aren't deployed: internal documentation, the docs repo itself.
- Libraries published with a version: there the check is installing the published
  version in a clean project, not opening a URL.

## What the project declares

The kernel doesn't know where each project lives. Its `crux.json` declares it:

```json
"deploy": {
  "url": "https://<domain>",
  "paths": ["/", "/<important-route>"]
}
```

With several deployable repos, one per repo:

```json
"deploy": {
  "repos": {
    "<repo>": { "url": "https://<domain>", "paths": ["/"] }
  }
}
```

`paths` are the few routes that are noticed if they fail: the home page and
whatever is used most. Not the whole sitemap.

## The walkthrough

### 1. Wait for the new version to arrive

**This wait runs in the background.** A deployment takes minutes and the session
doesn't sit in front of it: the watcher is launched there, you say it is running
and move on to the next thing. You come back when it reports.

A 200 right after merging is usually **the previous version** answering while the
new one builds. You have to wait for something only the new one has: text the
change adds, or the commit identifier if the application exposes it.

```bash
bash <this-skill-directory>/scripts/smoke.sh --expect "<text only the new version has>"
```

If the change adds nothing visible to look for, wait for the platform to report
the deployment as finished and say that the version could not be confirmed.

### 2. Routes respond

The same script checks each declared route: status code, time and whether the
body is actually an error page served with a 200, which some frameworks do.

Output: `0` everything responds, `1` some route fails, `3` the new version did
not arrive.

### 3. What the change touched

Generic routes don't see a specific change. Open **what the diff touched** in
production:

- **Interface**: look at it rendered on mobile and desktop, with `/visual-test`.
  Compare it with what was seen in the proposal's preview.
- **API**: call the affected endpoint with a real request that doesn't write
  data.
- **Data**: the migration is applied and the application starts against it.

### 4. If something fails

Don't fix blindly in production. In order:

1. **Roll back**: open a proposal with `git revert` of the merge and merge it.
   What comes back is something that already worked; the fix is done later,
   calmly and with its own cycle.
2. If the platform allows going back to the previous deployment with one click,
   that is faster than the revert, but **do the revert too**: otherwise the next
   deployment publishes the failure again.
3. Investigate with `/root-cause`, starting from the production signals
   (`/prod-signals`).

### 5. Report it

One line is enough if everything is fine: which version, which routes, how long
they took. If something failed: what, since when, what was done and what remains.

## What it costs

Almost nothing. The script doesn't read whole pages into the context: it returns
one line per route. The expensive part is step 3 when there is an interface, and
it is the same visual review already done in the preview, now against production.

## Anti-patterns

- **Assuming what was merged is deployed.** The platform may have failed, or may
  still be building.
- **Checking only the home page.** The change is almost never on the home page.
- **Hot-fixing on production.** First you go back to what worked; the fix goes
  through the cycle.
- **Rolling back from the platform and not in git.** The next deployment
  resurrects the failure.

## Related

- `/flow`: this is its step 6c
- `/visual-test`: to look at the interface in production
- `/prod-signals`: when something fails and you need to see what production says
- `/deploy-fallback`: when automatic deployment is not available
