---
name: oauth-reauthorize
description: Regenerate the refresh_token of an OAuth integration when the flow has been invalidated, bringing up an ephemeral local server that captures the callback code and saving the tokens with restrictive permissions. Use when an integration starts failing with invalid_grant on refresh, after manually revoking permissions, or when setting up a new machine where the token is missing.
---

# oauth-reauthorize

Redoes from scratch the OAuth flow of a desktop integration.

## When to use

- An integration returns `invalid_grant` on refresh. The usual symptom is that the
  provider expired the grant from lack of use, or someone revoked the permissions
  by hand.
- A new machine where the client file is already there but the token is missing.
- After revoking access manually.

## Preconditions

- A `client.json` of **desktop** type in the integration's configuration
  directory. The type matters, see the gotchas.
- The account you are going to authorize with actually has access to the
  resource.
- The loopback port you are going to use, free.

## Usage

```bash
python3 <this-skill-directory>/scripts/oauth-authorize.py \
  --dir ~/.config/<service> \
  --scope "<scope>"
```

Optionally `--port`, and `--auth-url`/`--token-url` if the provider is not
Google.

The script prints the consent URL and opens the browser. After accepting, the
provider redirects to `127.0.0.1`, the ephemeral server captures the `code`,
exchanges it for tokens and writes them with 600 permissions.

## Verify

Don't accept the flow just because the script says OK: **make a real query**
against the API with the freshly obtained `access_token`. A token that is written
but authorizes nothing is the easiest failure to overlook, and it appears when
the requested scope is not the one the API needs.

## Gotchas

- **The response doesn't include `refresh_token`.** It happens when the provider
  reuses a previous grant. The script already requests explicit consent and
  offline access to force a new one, but the safety net is to **revoke access by
  hand** on the account's permissions page and repeat.
- **`redirect_uri_mismatch`.** The OAuth client has to be of desktop type: those
  accept any port under loopback by default. Web-type ones require registering
  the exact URI.
- **The out-of-band flow is dead.** The `urn:ietf:wg:oauth:2.0:oob` that appears
  in old tutorials has been deprecated for years. Always loopback.
- **Don't use privileged ports** for the callback: they require root with no
  advantage.
- **A service account doesn't replace this** unless it has explicit permission on
  the resource. A service-account credentials file existing in the directory
  doesn't mean it works; many integrations only support user OAuth.

## Afterwards

The tokens are secrets: they stay with 600 permissions and are **not committed**.
If the project needs to renew them periodically, that lives in a separate script,
not here.

## Related

- The project's operational documentation, for the concrete scopes and resource of
  each integration
