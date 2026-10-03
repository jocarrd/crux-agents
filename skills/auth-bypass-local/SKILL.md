---
name: auth-bypass-local
description: Bypass authentication locally to test protected endpoints or UI without a real session, skipping both the server layer and the client layer at once, with a double lock that makes it impossible to activate in production. Use when you need to reproduce or debug an authenticated flow (admin panel, protected endpoints, roles) without being able to log in, when you want to skip the login to see a protected screen locally, including with a headless browser.
---

# auth-bypass-local

Really test what is behind the login, locally, without a session.

## The rule that makes it work

**There are two layers and both must be bypassed at once.** It is the mistake that
costs an afternoon: only the client guard is bypassed, you get into the UI, and
every call to the server returns 401 or 403. Or the other way round: the server
accepts, but the client guard doesn't even let the screen render.

| Layer | What it blocks | What to do |
| ----- | -------------- | ---------- |
| Server | The guard that validates the token and the one that checks the role | Return authorized and inject a fake user |
| Client | The component that wraps the protected routes | Let through without a session |

In addition, the client without a session will send requests **with no
authorization header**: the server with the bypass active has to accept them.

## The rule that makes it safe

**Double lock: an explicit environment variable AND the environment not being
production.** Both, in the same condition:

```
bypassActive = ENV_VAR === "1" && NODE_ENV !== "production"
```

That way, even if the variable leaks into a production environment, the bypass
still cannot activate. A single lock is not enough: a variable wrongly set in an
`env_file` opens your admin panel to the internet.

On the client, the variable must arrive **only through the development startup**,
never through a file that gets baked into the production build. Put it in the
local environment file that is in `.gitignore`, not in the one that gets
distributed.

## The client component detail

The guard usually calls hooks of the authentication provider. If you do the early
return before those hooks, you violate the rules of hooks and the application
crashes.

**Wrapper pattern**: the outer component decides whether there is a bypass and
returns the children directly; the component that calls the hooks stays isolated
in a child that is only mounted when the bypass is off.

Watch out for the authentication provider: it usually needs to stay mounted with
a valid public key, even with no session. Without that, the hooks that return
`null` start throwing exceptions.

## Verify

That the protected call responds **without a token**:

```bash
curl -i http://localhost:<port>/<protected-route>
```

It must return 200. If it returns 401, the server bypass is not active; if the UI
doesn't load, it is the client one.

## Drive the browser to see real bugs

Many failures of a protected panel are not visible with `curl`: JavaScript
crashes, error notices in the UI, requests that fail because of the preflight.
With the bypass in place you can drive a headless browser against the local
application, listening for page errors and responses with error codes.

A real case: a reordering used an HTTP method that the server's CORS
configuration did not allow. With `curl` the endpoint responded perfectly; from
the browser the preflight failed and the UI only said "Failed to fetch". **It was
only visible by driving the browser.**

Hence a gotcha worth remembering: **CORS configuration usually lists methods
explicitly**. A new endpoint with an unlisted method fails from the browser even
though it exists and works. Check it with an `OPTIONS` request declaring the
method.

## When finished

- Stop the local services you brought up.
- Check that the bypass variable didn't end up in any file that goes into a
  build.

## Related

- `/visual-test`: visual inspection of the UI once inside
