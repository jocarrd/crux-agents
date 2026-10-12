//! Credential formats that admit no discussion: if one appears, someone
//! pasted something real. These are searched for rather than "looks like a
//! password" because documentation is full of examples, and a warning that
//! shouts at every `changeme-dev` teaches people to ignore warnings.
//!
//! One list for every checker: two copies drift apart, and a secret gets
//! through the gap.

use regex::Regex;
use std::sync::OnceLock;

pub struct Fingerprint {
    pub name: &'static str,
    pub rx: Regex,
    /// Hosts after the `@` that do not count (a local URL is not a secret).
    pub local_hosts: bool,
}

pub fn fingerprints() -> &'static [Fingerprint] {
    static F: OnceLock<Vec<Fingerprint>> = OnceLock::new();
    F.get_or_init(|| {
        let f = |name, rx: &str| Fingerprint { name, rx: Regex::new(rx).unwrap(), local_hosts: false };
        vec![
            f("live Stripe/Clerk publishable key", r"\bpk_live_[A-Za-z0-9]{10,}"),
            f("live secret key", r"\bsk_live_[A-Za-z0-9]{10,}"),
            f("GitHub token", r"\bgh[pousr]_[A-Za-z0-9]{20,}"),
            f("AWS access key", r"\bAKIA[0-9A-Z]{16}\b"),
            f("JSON Web Token", r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\."),
            f("OpenAI API key", r"\bsk-[A-Za-z0-9]{32,}"),
            Fingerprint {
                name: "URL with a password inside",
                rx: crate::regex!(r"\b[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s/@]{6,}@").clone(),
                local_hosts: true,
            },
            f("private key", r"-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----"),
        ]
    })
}

const LOCAL: [&str; 4] = ["localhost", "127.0.0.1", "::1", "host.docker"];

impl Fingerprint {
    pub fn is_in(&self, text: &str) -> bool {
        if !self.local_hosts {
            return self.rx.is_match(text);
        }
        // What follows the `@` decides: the regex engine has no lookahead.
        // Every possible start is tried, as a backtracking engine would.
        let mut from = 0;
        while let Some(m) = self.rx.find_at(text, from) {
            let after = &text[m.end()..];
            if !LOCAL.iter().any(|h| after.starts_with(h)) {
                return true;
            }
            from = m.start() + text[m.start()..].chars().next().map(char::len_utf8).unwrap_or(1);
        }
        false
    }
}

/// The names of the fingerprints that appear in the text.
pub fn fingerprints_in(text: &str) -> Vec<&'static str> {
    fingerprints().iter().filter(|f| f.is_in(text)).map(|f| f.name).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_local_url_with_a_password_is_not_a_secret() {
        assert!(fingerprints_in("postgres://user:secretpw@localhost:5432/db").is_empty());
        assert_eq!(fingerprints_in("postgres://user:secretpw@db.example.com/db"), vec!["URL with a password inside"]);
    }
}
