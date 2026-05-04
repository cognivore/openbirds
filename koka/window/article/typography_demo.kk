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
  body("There is no way a single non-profit or commercial organisation can sustain a culturally sensitive and sensible content-rich self-care application.")
  body("Even the best-meaning people who have to pay salary to other people will make concessions to bottom-line.")
  body("It's the good old \"trust lock-in\" problem, which is solved by federation¹.")
  body("This is how OpenBirds came to life: a completely privacy-preserving, federated social habit-building app.")
  pull-quote("Trust cannot live in a cage, thus we are liberating it.")
  body("We are using a very powerful and a very nerdy way of programming — a research language called Koka, which allows us to write flawless and bug-free code, and we take a page from the hundred rabbits book and implement our own compositor, because otherwise it would be impossible to actually use all the Koka's great features in the application.")
  body("We hope that the community which will be built around OpenBirds will not only push the limits of what self-care applications can be, but also what effect-tracked computations can express.")
  code("pub fun render(p : page, sy : int) : pixel ()")
  code("pub fun with-host(action : () -> <host|e> a) : e a\n  with handler\n    fun now-seconds() ffi-now-seconds()\n  action()")
  body("From here we build mood tracking, breathing sessions, gentle pet companionship, append-only personal history, a friendship channel the server never reads. We, the contributors to OpenBirds, support artists by deploying their work into a comletely free to use platform, and commissioning exclusive art.")
  body("On LLM usage — no matter how innovative and fun to program computer languages are, trying to program those manually when the languages at large were captured by machine learning models² is irresponsible if we want to achieve results.")
  body("The energy argument also doesn't hold water (pun absolutely intended). In one Sunday we have implemented a system which would take approximately three months to implement by an expert human. It is clear that in three months of work, said expert would spend significantly more energy than servers which were predicting the best way to write OpenBirds core codebase.")
  body("Of course, we have piggy-backed decades of author's experience in programming language theory, as well as broad understanding of the domain; and furthermore, a lot of Koka code in OpenBirds is quite unfortunate, but it is extremely performant and any human is welcome to send well-explained improvements for the code style and potential software bugs.")
  body("In a bit of an irony, this project does not and will never use LLMs for any user-facing content.")
  pull-quote("This project will never use LLMs for content")
  body("Even enterprise software for sad office workers becomes absolutely depressing (often literally) when LLM slop is introduced. Self-care applications must have complete and total protection even from slop artifacts, let alone unbounded slop interactions like the so-called \"AI councelors\".")
  body("We hope that you will enjoy using OpenBirds.")
  body("[1]: See applications like mastodon and bookwyrm — social networks where you can move away from a server you no longer trust or simply no longer like, together with your data")
  body("[2]: Note, we deliberately don't say \"artifical intelligence implementaitons\" here, because these models do not possess intelligence, at most they possess logic.")
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
