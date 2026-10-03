// Credential formats that admit no discussion: if one appears, someone pasted
// something real. These are searched for rather than "looks like a password"
// because documentation is full of examples, and a warning that shouts at every
// `changeme-dev` teaches people to ignore warnings.
//
// They live here and not inside whoever uses them because two checkers need
// them —the documentation and the .mcp.json files— and the first time the two
// lists were copied they came out different: one lacked three fingerprints,
// among them the URL with the password inside, and through that gap a secret
// reached git.

export const FINGERPRINTS = [
  { name: 'live Stripe/Clerk publishable key', rx: /\bpk_live_[A-Za-z0-9]{10,}/ },
  { name: 'live secret key', rx: /\bsk_live_[A-Za-z0-9]{10,}/ },
  { name: 'GitHub token', rx: /\bgh[pousr]_[A-Za-z0-9]{20,}/ },
  { name: 'AWS access key', rx: /\bAKIA[0-9A-Z]{16}\b/ },
  { name: 'JSON Web Token', rx: /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\./ },
  { name: 'OpenAI API key', rx: /\bsk-[A-Za-z0-9]{32,}/ },
  { name: 'URL with a password inside', rx: /\b[a-z][a-z0-9+.-]*:\/\/[^\s/:@]+:[^\s/@]{6,}@(?!localhost|127\.0\.0\.1|::1|host\.docker)/ },
  { name: 'private key', rx: /-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----/ },
]

export function fingerprintsIn(text) {
  // fingerprintsIn <text> — the names of the fingerprints that appear in it.
  return FINGERPRINTS.filter(({ rx }) => rx.test(text)).map(({ name }) => name)
}
