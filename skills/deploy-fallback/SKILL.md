---
name: deploy-fallback
description: Deploy to your own server without going through CI, building the image locally and transferring it over SSH to recreate the container. Use when CI is unavailable or has run out of quota, when a branch that hasn't gone through review has to be deployed urgently, or as the documented plan B of a pipeline that depends on a third party.
---

# deploy-fallback

Alternative deployment route: build locally, transfer the image and recreate the
container. Slower than CI, but it depends on nobody.

## When to use

- CI ran out of quota or is down.
- A local branch has to be deployed urgently without going through the normal
  flow.
- You are validating that plan B exists **before** needing it, which is the only
  way it will work the day it is needed.

## The pipeline

```
docker build (with the production build-args)
  └─ docker save | gzip -1 | ssh <host> 'gunzip | docker load'
       └─ ssh <host> 'docker compose up -d --force-recreate <service>'
            └─ invalidate the CDN if there is one
```

`gzip -1` on purpose: on a home upload the bottleneck is the network, but
compressing to the maximum takes longer than it saves. Prioritize speed.

## Before launching

Check **what you are going to deploy**. By skipping CI you also skip the
guarantee that what goes up is what is on the main branch:

```bash
git -C <repo> status
git -C <repo> log -1 --oneline
```

## The trap of variables baked in at build

**The variables a frontend framework exposes to the browser are baked in at build
time, not at container startup.** It is the number one cause of deployments that
look correct and aren't.

Practical consequence: the server's environment file **does not work** for those
variables. If the local production file has a test key, the browser will start
with the test key even though the server runtime shows the production one, and
the services that depend on it will fail in confusing ways.

Verify the environment file it is built from, not the server's. And if you can,
make the script abort when it detects the wrong environment key: it is a two-line
check that pays for itself.

## Invalidate the CDN when finished

If there is a CDN in front, **purging it is part of the deployment, not an
extra**.

The typical failure: the CDN keeps serving the HTML of the previous build, which
requests static resources that no longer exist in the new container. Result: 404
errors on the bundles, the JavaScript doesn't start and features like login stop
responding with no visible error on the server.

Symptoms pointing exactly at this: the login button does nothing, errors about
server actions not being found, and 404s on the static asset routes. It is
confirmed in the browser console in ten seconds.

## Post-deployment verification

Don't accept a deployment without two checks:

```bash
curl -sS -o /dev/null -w "HTTP %{http_code} | %{time_total}s\n" https://<domain>/
ssh <host> 'docker ps --filter name=<service> --format "{{.Names}} | {{.Status}}"'
```

Expected: 200 and the container `Up` and healthy. If the healthcheck doesn't pass,
the container is up but the application isn't.

## Gotchas

- **A local build without CI's cache takes considerably longer** than you
  remember. Account for that before promising a five-minute deployment.
- **Services with a cache persisted across deployments** don't clean themselves:
  if you changed what they generate, it has to be purged separately.
- **If the recreate fails because of network dependencies between containers**,
  it is an orchestration problem, not a deployment one: see the project's
  incident playbook.

## Related

- The project's release documentation, for the canonical pipeline and the
  concrete server layout
