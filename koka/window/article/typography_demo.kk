// koka/window/article/typography_demo.kk — TYP-SRS-001 acceptance
// page, expressed in the article DSL.
//
// This is the same engineering-notebook page that
// `koka/typography_page.kk` previously produced by hand-rolling y
// cursor arithmetic per block. With the article DSL the description
// reads top-to-bottom in source order — every block is a one-liner,
// every spacing decision lives in `demo-theme`. The five canonical
// typefaces still pick up their TYP-SRS-001 roles:
//
//   "menu" / [X]              → Terminal Grotesque   (UI chrome)
//   "main()"                  → Terminus             (mono accent)
//   "Open self-care …"        → Jost*                (heading)
//   body prose paragraphs     → EB Garamond          (body)
//   `pub fun render …`        → Terminus             (code)
//   "Thus, we are liberating" → Cormorant Garamond   (pull quote)
//   "CLOSE"                   → Terminal Grotesque   (footer)
//
// Public surface preserved for `koka/render.kk` and the bench:
//   - `compose-scrollable-page(reg, gc, vs)` → scrollable-page
//   - `compose-scrollable-page-from-bare(reg, gc, w, h)` → scrollable-page
//   - `compose-page(reg, gc, w, h)` → rendered-page (bench-only path)

module window/article/typography_demo

import truetype/registry
import truetype/glyph_cache
import viewport
import window/article

// === ink palette =========================================================

pub val ink-rgba    : int = pack(230, 230, 224, 255)  // off-white text
pub val accent-rgba : int = pack(180, 200, 230, 255)  // softer, for chrome
pub val mono-rgba   : int = pack(170, 220, 170, 255)  // greenish for code
pub val quote-rgba  : int = pack(255, 230, 180, 255)  // warm cream pull quote

// === theme ===============================================================
//
// All sizing/spacing for the demo lives here. Numbers are tenths of
// a percent of viewport height (`hpct`), tuned against an ~iPhone-
// 17-Pro-class viewport (~852–956 logical px tall). Each role's
// `trailing-gap` is `line-step + post-block-comfort` so consecutive
// blocks read with a comfortable transition without per-call gaps.
//
// `pull-quote` adds an extra leading gap inside the helper itself
// (article.kk), so the quote breathes out from the surrounding
// body without the theme having to encode "what comes before".
pub fun demo-theme(h : int) : article-theme
  Article-theme(
    chrome-style     = Role-style("TerminalGrotesque",  hpct(h, 34), accent-rgba,
                                  hpct(h, 40),  hpct(h, 80),  0,            0),
    mono-style       = Role-style("Terminus",           hpct(h, 30), mono-rgba,
                                  hpct(h, 36),  0,            0,            0),
    x-tag-style      = Role-style("TerminalGrotesque",  hpct(h, 40), accent-rgba,
                                  hpct(h, 40),  0,            0,            0),
    heading-style    = Role-style("Jost",               hpct(h, 74), ink-rgba,
                                  hpct(h, 78),  hpct(h, 80),  0,            0),
    body-style       = Role-style("EBGaramond",         hpct(h, 34), ink-rgba,
                                  hpct(h, 40),  hpct(h, 94),  0,            0),
    code-style       = Role-style("Terminus",           hpct(h, 28), mono-rgba,
                                  hpct(h, 36),  hpct(h, 90),  hpct(h, 28),  hpct(h, 28)),
    pull-quote-style = Role-style("CormorantGaramond",  hpct(h, 50), quote-rgba,
                                  hpct(h, 54),  hpct(h, 108), 0,            0),
    button-style     = Role-style("TerminalGrotesque",  hpct(h, 90), ink-rgba,
                                  hpct(h, 90),  0,            0,            0)
  )

// === the page itself =====================================================
//
// Reads top-to-bottom the way it lays out top-to-bottom on screen.
// Add a block, change a paragraph, reorder a quote — the cursor,
// the wrap math, the run construction all live behind the DSL.

fun page-description() : <cursor, read<global>, div> ()
  chrome("menu", "main()")
  heading("Open self-care\non your terms.")
  body("There is no way a single non-profit or commercial organisation can sustain a culturally sensitive and sensible content-rich self-care application. The incentive shapes the product — ad-funded means your moods become inventory, paywall-funded means the people who actually need it cannot reach it.")
  code("pub fun render(p : page, sy : int) : pixel ()")
  body("The architecture commits to one rendering primitive: an RGBA byte buffer. Koka does the brain work — every effect that touches the network, storage, or the platform has to declare itself in the type system, so we cannot accidentally leak a mood across the FFI without the compiler shouting at us. Pretty robust seam, in practice.")
  pull-quote("Thus, we are liberating it.")
  body("Friendship channels are X3DH plus Double Ratchet. Identity is an Ed25519 keypair you keep on your device, and the user-facing friend code is just a public-key fingerprint. No email, no phone, no username server-side. No directory. If you want to add a friend you exchange fingerprints — by QR code, by reading them out loud, whatever feels appropriate. The trust decision is yours.")
  body("Local-first by construction: every feature works offline. Sync is opt-in and additive — bring your own server (a Hetzner box, a friend's Raspberry Pi, a Cloudflare R2 bucket) where the server only sees encrypted blobs and content addresses. We never see your data. We cannot.")
  body("No telemetry. No analytics. No third-party SDKs. Zero. The business model is a one-time purchase or platform-billed subscription, never user data. If that sounds religious, it is — every small data leak is a brick in the surveillance economy you wake up to in five years and cannot unbuild. We refuse to lay the brick.")
  body("From here we build mood tracking, breathing sessions, gentle pet companionship, append-only personal history, a friendship channel the server never reads. Every pixel comes from this Koka brain. Pretty tight design constraint, all of it. Let us see what we can build.")
  close-button("CLOSE")

// === public composition entry points =====================================
//
// `render.kk` calls `compose-scrollable-page` once per cache miss
// (font registration, viewport-spec change). The bench calls
// `compose-page` to time cold + warm composes against the glyph
// cache.

pub fun compose-scrollable-page(reg : font-registry, gc : glyph-cache,
                                vs : viewport-spec)
        : <div, read<global>, write<global>> scrollable-page
  compose-article(reg, gc, vs, demo-theme(vs.vp.height), page-description)

pub fun compose-scrollable-page-from-bare(reg : font-registry, gc : glyph-cache,
                                          w : int, h : int)
        : <div, read<global>, write<global>> scrollable-page
  compose-scrollable-page(reg, gc, bare-spec(w, h))

pub fun compose-page(reg : font-registry, gc : glyph-cache, w : int, h : int)
        : <div, read<global>, write<global>> rendered-page
  compose-fixed(reg, gc, w, h, demo-theme(h), page-description)
