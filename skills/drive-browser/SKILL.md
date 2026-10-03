---
name: drive-browser
description: Drive a browser WITH the user's already-logged-in session from the terminal (navigate, click, fill, capture) over the debugging protocol (CDP), when no browser MCP tool is available. Use when you have to operate an authenticated external panel —Vercel, Stripe, a dashboard, a provider's console— reusing the cookies of the user's Chrome; when they say "conéctate a mi navegador", "usa mi sesión", "hazlo tú en Vercel/Stripe"; or when you try to open a debugging port and Chrome rejects it or lands on the login screen.
---

# drive-browser

Control the user's Chrome, with its session cookies, from the terminal over CDP
(`--remote-debugging-port`), when an authenticated website has to be operated
and there is no browser tool. Why each restriction:
`<this-skill-directory>/references/por-que.md`.

**Do not use** for screenshots of your own local app (`/visual-test`), nor if a
browser MCP is available: check with `claude mcp list`. If you are going to
repeat this, install one (it loads when the agent restarts):
`claude mcp add chrome-devtools -s user -- npx -y chrome-devtools-mcp@latest --browser-url http://127.0.0.1:9222`.

## Needed

- `google-chrome` and a **desktop session** (`echo $DISPLAY` non-empty): it has
  to be headed.
- `python3` with `websockets`.
- The keyring unlocked (it is if the user has Chrome open).

## Procedure

1. **The profile with the session** (it is usually not `Default`):

   ```bash
   python3 - <<'PY'
   import sqlite3, glob, os
   ch=os.path.expanduser("~/.config/google-chrome")
   for p in glob.glob(ch+"/*/Cookies"):
       c=sqlite3.connect(p)
       n=c.execute("select count(*) from cookies where host_key like '%vercel%'").fetchone()[0]
       print(p, "->", n); c.close()
   PY
   ```

2. **Launch headed Chrome on a copy of the profile**, as a persistent background
   task:
   `<this-skill-directory>/scripts/chrome-session.sh ~/.config/google-chrome/"Profile 1"`.
   Wait for `curl -s http://127.0.0.1:9222/json/version`.

3. **Check that the session came across:**
   `python3 <this-skill-directory>/scripts/cdp.py goto https://vercel.com/dashboard /tmp/dash.png 6`.
   If it ends up on the login page, decryption failed (almost always from
   launching headless).

4. **Drive** with short, separate calls:
   - Click: **the `click` action of `cdp.py`**, which sends real mouse events.
     JS `.click()` or a synthetic `MouseEvent` trigger nothing on many SPAs; use
     them only if `click` does not find the element.
   - Read and execute: `cdp.py eval '<js>'` and `cdp.py evalshot '<js>' <png> <s>`.
   - Controlled inputs: the native setter and `input`/`change`. With
     autocomplete, set the value to "" with the setter and then `type`; if the
     dropdown does not appear, Enter.
   - In React many buttons are `div`: find them by text.

5. **When finished**, close by port and delete the copy, which has cookies:

   ```bash
   fuser -k 9222/tcp; rm -rf /tmp/cdp-profile
   ```

## Secrets: never print them

Leave the value in `window.__X__` and dump it to a file with `writefile`, which
writes with `chmod 600` and prints only the length:

```bash
python3 .../cdp.py eval 'window.__X__=document.body.innerText.match(/DATABASE_URL=(\S+)/)[1]; "len="+window.__X__.length'
python3 .../cdp.py writefile 'window.__X__' /tmp/secret
```

## Gotchas

- **Google does not accept the copied profile:** ask the user to sign in once in
  the headed window and carry on yourself. Other sites do accept the cookies.
- **Chrome does not debug the default profile** and you cannot attach to the
  user's real Chrome: always a copy in another `--user-data-dir`.
- **Headless does not decrypt the cookies:** headed, with
  `--password-store=gnome-libsecret` and also copying `Local State` (the script
  already does).
- **If `eval` hangs,** do not kill Chrome: open a new tab
  (`curl -s -X PUT "http://127.0.0.1:9222/json/new?<url>"`) and close the old one
  (`/json/close/<targetId>`).
- **Kill by port (`fuser -k 9222/tcp`), never with `pkill`.**
- **The environment kills background processes** when each call ends: Chrome
  goes as a persistent task.
- `urllib` to `127.0.0.1` may go out through a proxy; `cdp.py` already avoids it.
- The scrolling container is the `div` with `scrollHeight > clientHeight`.

## Related

- `/visual-test` — headless screenshots of your app, without a session
- `/share-local` — open your local environment to the outside
- `/oauth-reauthorize` — when an OAuth token fails, not the web session
