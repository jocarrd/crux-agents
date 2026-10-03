# The details of each problem

The procedure is in `SKILL.md`. Here are the why and the long material.

## Why check before handing out the link

cloudflared warns about it itself: *"may take some time to be reachable"*.
Sometimes it is seconds and sometimes the name never resolves (`NXDOMAIN` even
asking `1.1.1.1`) with the tunnel perfectly registered on the other side.

The `npx` route also sidesteps the policy of not downloading loose binaries from
the internet. Installing a binary just for this is more surface than the problem
deserves.

## The two SSH details that cost half an hour

- Without `-tt`, the service opens the tunnel but does not print the address,
  and you are left with a connected process and no URL.
- With your own unregistered key, the service answers `Permission denied
  (publickey)` after showing the welcome greeting, which is misleading.

## Absolute addresses

It is the failure that makes the tunnel "not work" when it works perfectly. The
application writes its address into links, stylesheets and images; if it is
`localhost`, whoever enters from outside receives a page that sends them to look
for the resources on their own computer. You see the site perfectly because you
do have something on that port.

Checking for what is not local, instead of maintaining a list of tunnel
providers, avoids coming back here every time the service changes. Without
marking the connection as secure, the application generates mixed links that the
browser blocks.

## Why a supervisor

A tunnel session drops by itself. Leaving the process bare means that half an
hour later the person you were showing it to sees an error and you do not find
out. Without `setsid` the process dies with you: it has to hang from `init`, not
from your terminal.

Do not look for the process with `pkill -f`: the pattern also appears in the
command line of the shell that runs the `pkill`, which kills itself. Filter by
PID.

## The address changes without warning

Free services only give a fixed subdomain to registered accounts: both
localhost.run and Serveo ask you to register your public key by signing in with
Google or GitHub.

Worse: the address can change **without the connection dropping**. The process
stays alive and the address you handed out starts returning 503. A supervisor
that only reads the address when opening the session keeps pointing at the old
one. That is why it is reread while the connection lives:

```bash
while kill -0 "$ssh_pid" 2>/dev/null; do
  url=$(grep -oE '[a-z0-9-]+\.lhr\.life' "$salida" | tail -1)   # tail, not head
  [ "$url" != "$ultima" ] && { ultima="$url"; echo "https://$url" > "$fichero"; }
  sleep 3
done
```

The output keeps every address the session has had, and the good one is the
last: hence the `tail -1`.

If it really must not change, choose the route (registering the key, a named
tunnel under your own domain, a remote redirect) before starting, not after
having handed out the link.

## When finished

While the tunnel stays open, your machine is on the internet.
