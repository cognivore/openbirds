# Typography — five typefaces, one role each

> **Source:** TYP-SRS-001 r1.0 (2026-05-03), reproduced verbatim
> below as a contributor reference. The architectural rule is in
> [§3 Constraints](#3-constraints) below; if a future change wants
> to reach for a different typeface, justify against §3 first.

## 1. Purpose

Define the typographic system for the framework. Identify five
typefaces, assign each to a single role, and state the licensing,
rendering, and historical-coherence rationale that makes each
selection non-substitutable.

## 2. Scope

The framework renders directly to a framebuffer. Glyph placement is
performed by the system kernel, not delegated to platform
text-rendering layers. Type selection is therefore an
**architectural** concern, not a styling concern. All five typefaces
shall be bundled with the framework and shall be the canonical
defaults; user override is permitted but not required.

## 3. Constraints

- **C-1 License:** All bundled typefaces shall be distributed
  under the SIL Open Font License 1.1.
- **C-2 Redistributability:** Downstream forks, embedding in
  compiled applications, and modification (including subsetting
  and re-hinting) shall be permitted without further grant.
- **C-3 Rendering authority:** The framework controls glyph
  placement at known pixel sizes. Bitmap fonts are admissible
  where role-appropriate.
- **C-4 Historical coherence:** Selections shall belong to a
  unified intellectual tradition spanning Renaissance humanism,
  Bauhaus geometric modernism, French libre type, and Unix
  console heritage.

## 4. Role assignments

### 4.1 Body prose — `EB Garamond`

- **Designer:** Georg Mayr-Duffner (2011); expanded by Octavio Pardo.
- **Source:** Egenolff–Berner specimen, 1592 (Claude Garamond
  roman, Robert Granjon italic).
- **Role:** Long-form reading text in documentation, articles, and
  prose surfaces.
- **Rationale:** Direct lineage to the humanist Garaldes that
  defined 1984-era Apple body typography. Carries Latin, Greek,
  Cyrillic, and IPA. Optical sizes, true italic, oldstyle figures,
  small caps. Erik Spiekermann has called it one of the best
  open-source fonts; the assessment holds.

### 4.2 Display prose — `Cormorant Garamond`

- **Designer:** Christian Thalmann (Catharsis Fonts), 2015.
- **Role:** Pulled quotes, large editorial prose moments,
  prose-adjacent display work where Jost would be tonally wrong.
- **Rationale:** Sharper, higher-contrast, Garamond-DNA companion
  to EB Garamond. Exploits high-resolution rendering at display
  sizes. Optional in the stack; included for editorial surfaces.

### 4.3 Headings — `Jost*`

- **Designer:** Owen Earl (Indestructible Type), 2017.
- **Role:** Section titles, hero text, document titles, any large
  display setting that demands architectural authority.
- **Rationale:** Open-source clean-room reimplementation of the
  Renner / Futura / ITC Avant Garde geometric tradition. Nine
  weights from Hairline to Black with matching italics. Supplies
  the Bauhaus pole of the system. Variable-axis available; static
  cuts sufficient for framebuffer use.

### 4.4 Menu and UI chrome — `Terminal Grotesque`

- **Designer:** Raphaël Bastide (Velvetyne Type Foundry).
- **Role:** Navigation, buttons, tabs, sidebars, dropdowns,
  labels — all small-to-medium UI text where the framework
  speaks in its own voice.
- **Rationale:** A grotesque with retained character at small
  sizes. Wonky terminals and a slightly-degraded photocopier
  quality give the chrome a voice that neutral grotesques (Inter,
  Helvetica, Roboto) flatten away. Cultural alignment with
  Velvetyne's libre-type tradition. Single-weight; emphasis in
  chrome shall be carried by colour, fill, and Jost Medium where
  typographic weight is required.

### 4.5 Monospace and terminal — `Terminus`

- **Designer:** Dimitar Zhekov, 2002–present.
- **Role:** All monospaced text — code, logs, terminal output,
  inline code in documentation, hex dumps, address fields.
- **Rationale:** Bitmap font designed at exact pixel sizes (6×12,
  8×14, 8×16, 10×20, 11×22, 12×24, 14×28, 16×32). Aligned with
  the framework's glyph-placement model: known pixels at known
  sizes, no anti-aliasing imposed by an intermediate layer. The
  canonical Linux console face. Substantial historical weight;
  not a homage, the source.

> Terminus's TTF conversion (Tilman Blumenbach,
> [files.ax86.org/terminus-ttf](https://files.ax86.org/terminus-ttf/))
> is the canonical bundled artifact. Using TTF for all five
> typefaces gives the rasterizer a single code path.

## 5. Pairing requirements

- **R-1** Headings shall be set in Jost\* at weight ≥ Medium for
  body context and Hairline–Light for hero context.
- **R-2** Body prose shall default to EB Garamond Regular. Italic,
  small-caps, and oldstyle figures shall be enabled where the
  rendering target supports OpenType features.
- **R-3** UI chrome shall default to Terminal Grotesque Regular.
  Selected, active, and hover states shall be expressed through
  colour and fill rather than weight.
- **R-4** Monospace contexts shall use Terminus at the nearest
  supported pixel size to the requested logical size. Scaling
  between supported sizes is prohibited.
- **R-5** No more than three of the five typefaces shall appear
  simultaneously on a single rendered surface.

## 6. Excluded options and rationale

| Candidate | Reason for exclusion |
|---|---|
| Inter, Geist, IBM Plex Sans | Tonally neutral; absent voice. |
| Pangram Pangram, Klim, Colophon, Atipo | Non-OFL; license terms incompatible with C-1, C-2. |
| Departure Mono, Sligoil, JetBrains Mono | Vector mono fonts are role-redundant given C-3 and the selection of Terminus. |
| Le Murmure, Basteleur (for prose) | Quirky display character degrades at body reading sizes. |
| Cormorant Infant, Cormorant Upright | Stylistic variants of the selected Cormorant cut; unnecessary. |

## 7. Acceptance

This specification is approved when **all five typefaces are
bundled** in the framework distribution under their OFL notices,
the role assignments in §4 are wired into the default theme, and
the pairing requirements in §5 are enforced by the rendering layer.

---

## Implementation status (working notes)

This section is **not** part of the spec — it tracks where the
implementation currently stands.

### Done

- `koka/font.kk` — bitmap-font primitives + glyph-pixel lookup.
- `koka/text.kk` — per-pixel text compositor (`text-pixel(t, x, y)`)
  used inside `build-pixels` so text rendering is allocation-free
  in the hot loop.
- Embedded **5×7 placeholder font** (uppercase Latin + digits +
  basic punctuation) standing in for Terminus until the TTF path
  lands. Source data inlined in `font.kk` as `mono5x7`.
- `openbirds_load_font(name, bytes, len)` C bridge function +
  Swift bundle-loader scaffolding. Today this stubs (logs `name`,
  no-ops). Once the TTF path is in, the same call wires real
  fonts.
- Viewport-sized framebuffer: Swift sends `GeometryReader.size` to
  the renderer per frame; no fixed internal resolution.
- Idle-screen close button uses the typography system (label is
  rendered text, not an inline X glyph).

### Pending

- Vendor `stb_truetype.h` into the kklib unity / bridge build.
- `host/macos/font_native.{c,h}` — thin C wrapper:
  `kk_font_load(bytes, len) → handle`,
  `kk_font_rasterize_glyph(handle, codepoint, px) → bytes`,
  `kk_font_advance(handle, codepoint, px) → int`.
- Koka extern bindings + a `font/registry` module that maps
  `name → handle`.
- Glyph cache (per-font, per-codepoint, per-px) so we don't
  re-rasterize per render.
- Bundle the five OFL TTFs in `host/ios/Resources/fonts/`
  (gitignored binaries, downloaded by `just fetch-fonts` from
  upstream sources):
  - EB Garamond:        Google Fonts repo
  - Cormorant Garamond: Google Fonts repo (Catharsis Fonts upstream)
  - Jost\*:             Indestructible Type / Google Fonts
  - Terminal Grotesque: Velvetyne Type Foundry
  - Terminus:           files.ax86.org TTF conversion
- `koka/typography.kk` — role API per §4 + §5 (`heading`, `body`,
  `display`, `chrome`, `mono`) returning a configured renderer.
- R-4 enforcement: Terminus calls map to the nearest supported
  pixel size (refuse to scale between supported cuts).
- R-5 enforcement: track typeface usage per surface, lint at
  render time when >3 are active.
