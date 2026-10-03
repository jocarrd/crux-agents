# Why it is driven this way

The procedure is in `SKILL.md`.

## Why it is needed

The typical job is "entra en mi Vercel y conéctame la base de datos". Without a
browser tool there is no native way to navigate or click, so the bridge is
fabricated: a live, authenticated Chrome session, and a CDP client that sends it
`Page.navigate`, `Runtime.evaluate` and `Page.captureScreenshot`. The terminal
agent does not usually ship with a browser MCP by default (only the claude.ai
ones: Gmail, Drive…), and the Chrome extension cannot be invoked from here.

## Why a copy of the profile

Chrome refuses to debug the default profile: `DevTools remote debugging requires
a non-default data directory`. A profile also does not admit two instances, so
you cannot attach to the user's real Chrome. Two Chromes coexist without trouble
in different `--user-data-dir`s.

## Why headed

Cookies are encrypted with the system keyring. Headless does not decrypt them
and the login screen appears even though you copied them. `Local State` carries
the wrapped key, which is why it is copied together with `Cookies`.

## Google

The cookies travel and are decrypted (`SID`, `HSID`, `__Secure-1PSID` are seen),
but Google binds them to the originating device and the account chooser comes up
with "Sesión cerrada". Malt and Vercel do accept them.

## The click

React ignores untrusted events in some components: neither `element.click()` nor
a synthetic `MouseEvent` with `dispatchEvent` fire them.
`Input.dispatchMouseEvent`, which is what the `click` action of `cdp.py` uses,
was the difference between progressing and not progressing in a full sign-up.
JS `.click()` works elsewhere because the event bubbles up to React, which is why
it stays as the second option.

## pkill

`pkill -f "remote-debugging-port=9222"` matches your own command line and sends
SIGTERM to itself (it exits with 143 or 144 without doing anything). In addition
the destructive-command guard blocks it.

## Hung tabs

A tab can leave `Runtime.evaluate` hanging while CDP keeps answering over HTTP.
Killing Chrome would lose the session.

## Background processes

The agent's environment kills background processes when each call ends. That is
why Chrome is launched as a persistent task and driven with short calls; the
profile copy keeps the cookies between them.
