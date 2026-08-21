# unoyama/public

Static public website for **Unoyama Holdings**, served at
<https://www.unoyama.com> (apex `unoyama.com` should redirect to, or serve the
same content as, the `www` host).

**Everything in this repository is public and published under the Unoyama
Holdings name.** Do not add anything here that is not intended to be read by
anyone on the internet — no internal notes, no credentials, no vendor or
counterparty data, no unredacted financials.

## Why this site exists

Unoyama Holdings is a private holding company. It holds no customer
information, publishes no public applications, and offers no products or
services to end users. Any software it builds is for its own internal use.

The site exists to provide a public presence and the standard set of public
legal URLs that third-party platforms ask for before issuing production API
credentials. The pages are deliberately generic: they describe a holding
company with a static website and internal-only software, and they do **not**
claim customers, end users, or a public product.

## URL map

| File | URL | Intuit portal field |
| --- | --- | --- |
| `index.html` | `https://www.unoyama.com/` | Launch URL |
| `legal/privacy.html` | `https://www.unoyama.com/legal/privacy` | Privacy policy URL |
| `legal/eula.html` | `https://www.unoyama.com/legal/eula` | EULA URL |
| `legal/connect.html` | `https://www.unoyama.com/legal/connect` | Connect / reconnect URL |
| `legal/disconnect.html` | `https://www.unoyama.com/legal/disconnect` | Disconnect URL |

Host domain: `unoyama.com`.

Note: internal links use extensionless paths (`/legal/privacy`). GitHub Pages
serves `privacy.html` for that path, so this works as published — but it will
404 if you open the files directly from disk with `file://`, and it depends on
that Pages behavior. If you would rather not rely on it, change the links to
include `.html` and supply the `.html` URLs to match.

## Setup notes

- No build step. Plain HTML, inline `<style>` per page, no JavaScript, no
  external assets or fonts. CSS is duplicated across pages on purpose.
- Light and dark rendering via `prefers-color-scheme`.
- A custom domain on GitHub Pages needs a `CNAME` file containing
  `www.unoyama.com` plus the matching DNS records, and **"Enforce HTTPS"**
  enabled in the repository's Pages settings. Both are required — HTTPS URLs
  are mandatory for the Intuit portal fields above. *(Neither is included in
  this directory — add them when the repo is created.)*

## Before publishing — required

**The legal text is a draft and must be reviewed by a human, and ideally by
counsel, before this goes live.**

Resolve every placeholder first. Placeholders used throughout:

- `[LEGAL ENTITY SUFFIX — confirm]` — the full legal name (LLC, Inc., …) is not
  documented. Appears on every page.
- `[CONTACT EMAIL — confirm]` — `legal/privacy.html`, `legal/eula.html`,
  `legal/connect.html`, `legal/disconnect.html`.
- `[EFFECTIVE DATE — confirm]` — `legal/privacy.html`, `legal/eula.html`.
- `[GOVERNING LAW — confirm]` — `legal/eula.html`. No jurisdiction is assumed.
- `[YEAR — confirm]` — copyright year in every footer.

Find them all:

```
grep -rn "confirm" .
```
