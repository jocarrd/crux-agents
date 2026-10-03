---
name: share-local
description: Open the local environment to someone outside with a public tunnel, without deploying anything. Picks the available route, fixes the application's absolute addresses so the page does not arrive broken, checks that it really renders from outside and leaves the tunnel closed when finished. Use when you need to show work in progress to a client or a colleague, review a design among several people, test on a real phone, or receive a call from an external service that needs a public address.
---

# share-local

Publishes what runs on your machine under an internet address, without
deploying. The details of each problem and the full supervisor are in
`<this-skill-directory>/references/por-que.md`.

**It is not a permanent test deployment:** the tunnel lasts as long as the
session and its address changes. For something stable, deploy.

## Before opening anything

The tunnel exposes **everything that port serves**. Check out loud: is there an
admin panel without a password? does the local database hold personal data? are
keys or environment files being served? If any answer is yes, close it first or
do not open the tunnel. A random address is not security.

## Choosing the route

**1. cloudflared**, without installing anything:

```bash
npx --yes cloudflared tunnel --url http://localhost:<port>
```

The address lasts the session, but sometimes it takes a while to resolve or
never does (`NXDOMAIN`). Check that it responds before handing out the link.

**2. Plain SSH**, if the first does not resolve. It responds in seconds; the
address rotates:

```bash
ssh -tt -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 \
    -o ExitOnForwardFailure=yes -R 80:localhost:<port> nokey@localhost.run
```

`-tt` is mandatory (without it the address is not printed) and the user is
`nokey@` (with your own key you must have registered it). Do not install a
downloaded binary just for this.

## Absolute addresses

If the application stores its own address as `localhost`, from outside a blank
or unstyled page arrives while you see it fine. It lives in places like
`WP_HOME`/`WP_SITEURL` in WordPress, the public URL variable of a JavaScript
framework, or a `base_url`/`app_url`.

The address is deduced from the request when it is not local, and the
connection is marked as secure (the tunnel encrypts outwards and talks to you
over HTTP):

```php
$host = $_SERVER['HTTP_HOST'] ?? '';
$es_local = $host === '' || preg_match('/^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/', $host);
if (!$es_local) {
    $_SERVER['HTTPS'] = 'on';
    define('WP_HOME', 'https://' . $host);
    define('WP_SITEURL', 'https://' . $host);
}
```

## Check that it renders

That the process is still alive means nothing. Request the page through the
public address:

```bash
curl -sS -o /tmp/tunel.html -w "%{http_code} · %{size_download} bytes\n" \
     -m 45 https://<tunnel-address>/<path>
grep -c "localhost" /tmp/tunel.html     # 0, or almost
```

And open it at a phone's width. References to `localhost` stored in the
database (favicon, canonical) are usually cosmetic.

## If it has to last

Supervise it: a loop that reopens the connection when it drops, with growing
back-off, decoupled from the session (`setsid`) and that **rereads the address
while the connection lives** and writes the current one to a file (the last one
that appears in the output, not the first). The address can change without the
connection dropping. The example supervisor is in the reference.

Each reconnection brings a new address. Do not promise a stable address without
having registered the key with the service first, a tunnel with its own domain
or a redirect against a server of yours.

## When finished

Close the tunnel **by its PID**. Never with `pkill` or `killall`: they kill other
processes by name, and the destructive-command guard blocks them.

```bash
pgrep -af "localhost.run|cloudflared"   # locates the PID
kill <PID>
```

If you launched it in the background in an agent session, it does not close by
itself when the conversation ends.

## Signs that something is wrong

| What you see | What it usually is |
|---|---|
| Tunnel connected but no address | Missing `-tt` |
| `Permission denied (publickey)` after the greeting | Your key is not registered; use `nokey@` |
| Blank page from outside, fine from inside | Absolute addresses to `localhost` |
| Styles missing and mixed-content warnings | The application does not know the connection is HTTPS |
| Slow and intermittently down | Free-service limit; for something sustained, deploy |
