---
name: brand-guidelines-page
description: >-
    Designs and builds a single, highly polished HTML brand design guidelines page for any brand — color palette,
    typography, logos, favicons, live button / form-field / card demos, and written usage instructions, with both
    light and dark mode variants. Use when the user asks for a brand guidelines page, brand style guide, brand book
    webpage, design tokens reference page, or a page documenting brand colors, fonts, logo usage, or component
    styling. Not a full design system — the deliverable is one self-contained HTML reference page that lets another
    developer build a visually consistent site.
license: https://github.com/wickedbyte/agent-skills/blob/main/LICENSE
---

# Brand Guidelines Page

Build a **single HTML page** that documents a brand precisely enough that a developer who has never seen the
brand's website can produce visually consistent work from the page alone. The page covers: color palette,
typography, logos, favicons, interactive element demos (buttons, links, cards, form fields), and written usage
instructions — in both light and dark modes.

This is **not** a full design system. Don't document grids, breakpoints, motion systems, content patterns, or an
exhaustive component catalog unless the user asks. (Documenting the one or two signature components the brand
actually reuses — e.g. its content card — is in scope; inventing a component library is not.) Scope discipline is
part of the polish.

## The Three Non-Negotiables

1. **The page is the brand's first artifact.** It must itself be designed _in_ the brand it documents — its
   typography, colors, spacing, and section-opener pattern all use the brand's own values. A brand guidelines page
   that looks generic has failed regardless of how accurate its content is.
2. **Every visual fact is also a written fact.** A developer must never need browser devtools to extract a value.
   If a swatch shows a color, the hex is printed beside it. If a button demo has a hover effect, the exact hover
   values (color, opacity, shadow, transition duration) are written next to the demo. Show _and_ tell, always.
3. **The page is a reference, not a showcase.** This is where these pages most often turn to slop. Two failure
   modes, both forbidden:
    - **Marketing copy.** The page's words are usage instructions and brand facts — nothing else. No positioning
      statements, taglines, aspirational one-liners, or "the single source of truth for building a visually
      consistent…" filler. A masthead needs the logo, the title, and a version/date — not a sales pitch. If a
      sentence doesn't state a fact or a rule a developer will act on, cut it.
    - **Invented design.** Build the page only from treatments the brand actually uses. Don't add glassmorphism,
      decorative gradients, blur, animations, or color effects that aren't in the source design system — even if
      they'd look "premium." Borrow the brand's real nav, card, and button treatments verbatim. An effect the brand
      has never used is a brand violation, not a polish. When unsure whether a flourish is on-brand, leave it out.

## Phase 1 — Discover the Brand

Never invent brand values. Gather them from real sources, in this order of authority:

1. **Existing design-system documentation** — look for skills (`**/skills/**`), `BRAND.md`, `DESIGN.md`, style
   guides, or README sections describing colors and typography.
2. **Theme/token source files** — CSS custom properties (`@theme` blocks in Tailwind v4, `:root` variables),
   `tailwind.config.js`, SCSS variable files, design-token JSON.
3. **The implemented site** — buttons, navigation, links, cards, and form components in the codebase. Extract real
   hover, focus, active, visited, and disabled values from the actual classes and CSS, not from memory. Note the
   brand's section-opener pattern (e.g. an eyebrow label above the heading), its nav behavior, and its theme toggle.
4. **Asset directories** — logo files (all variants: standard, inverse, with/without tagline, square), favicon
   files (`favicon.svg`, `.ico`, sized PNGs, `apple-touch-icon`, `site.webmanifest`), and brand fonts.

Build a fact sheet before writing any HTML:

- **Colors**: every brand color with name/token, hex, RGB, and its role. Note which colors change between light
  and dark mode and what the borders, backgrounds, and text colors are in each mode.
- **Typography**: font families (with full fallback stacks), weights actually loaded, where each family is used,
  the type scale (element → size → weight → line-height), letter-spacing rules, and the section-opener pattern.
- **Interactive states**: for links and primary/secondary buttons — default, hover, focus-visible, active,
  visited (links), disabled. For form fields — default, focus, filled, error, disabled. For cards — shell, hover,
  and any sub-parts (accent bar, cover, tag pills, footer link row).
- **Logos**: every variant file, which background each is for, and any usage rules (minimum size, clear space,
  things not to do).
- **Favicons**: every file, its size, and where it's referenced (`<link>` tags, webmanifest).
- **Effects**: border radii, shadows, transition durations, and any blur/glassmorphism the brand genuinely uses —
  record only treatments that already exist in the brand, so you can reproduce them and avoid inventing new ones.

**If a fact is missing** (e.g. no documented visited-link color, no disabled field style), check the live code
once more; if it genuinely doesn't exist, choose a value consistent with the palette and mark it on the page as
_"proposed — not yet used on the live site"_. Never silently fabricate and present as canon. Once the user adopts a
proposed treatment, drop the label — don't leave stale "proposed" badges on things that are now canonical. If core
facts are missing (no palette at all, no logo files), stop and ask the user rather than inventing a brand.

## Phase 2 — Page Architecture

One self-contained HTML file. Sections in order. If the brand uses an **eyebrow + heading** section opener (a small
uppercase label above the `<h2>`), use it for this page's own section headers — the guidelines should be built from
the same patterns they document. Group sections under short category eyebrows (e.g. Identity, Foundations,
Components, Standards, Reference).

### 1. Masthead

Brand logo, page title (`<h1>` — e.g. "Acme Brand Guidelines"), and a version or "last updated" line. Render it in
the brand's own hero treatment (e.g. on the brand's dark hero background/gradient if it has one). The **light/dark
toggle** lives here too (see Phase 3). Keep it quiet: logo, title, date. **No positioning statement, no tagline, no
marketing sentence** — the masthead sets the restrained tone for the whole page.

### 2. Sticky section navigation

A slim sticky nav with anchor links to each section, in the brand's own nav treatment (e.g. pinned dark in both
modes if that's how the brand's nav behaves — don't restyle it with effects the brand doesn't use). It must be
genuinely responsive: on narrow screens collapse the links behind a **hamburger button** that opens an accessible
panel. When the panel is collapsed it carries both `aria-hidden="true"` and `inert` so keyboard focus can't enter
it; it closes on Escape and on link tap. The theme toggle stays visible and reachable on the bar at every width. A
horizontal-scroll strip of links is not good enough.

### 3. Logo

- Every variant rendered at a sensible size, each on a tile whose background matches its intended use — the
  inverse/light logo on a **fixed dark tile**, the standard logo on a **fixed light tile**, regardless of the
  page's current theme. Labeled tiles ("On light backgrounds") make the intent unambiguous.
- Arrange the variants in a **centered grid** (e.g. 2×2 on medium+ screens) rather than a ragged full-width row.
- Give each card a **download control** in its top-right corner — a native `<a download href="…">` so it works
  with JS disabled — that saves the displayed asset. Anchor it to the **card chrome** (so it follows the page
  theme), **not** over the mode-pinned preview tile; style it as a subtle brand-colored chip that stays legible in
  both themes.
- Under each variant: file name/path, intended background, and when to use it.
- **Clear space and minimum size** stated in writing (mark as proposed if the brand hasn't codified them).
- A short **"don't"** list in prose: don't recolor, stretch, or place the standard variant on dark backgrounds,
  etc. Only real risks; skip boilerplate.

### 4. Favicons

- Render the actual favicon files at their true sizes (16, 32, 180, 192, 512 as available) — small icons at
  natural size communicate more than a blown-up preview. Show each on both a light and a dark tile, labeled with
  file name and purpose (browser tab, apple-touch-icon, PWA icon, maskable). Give each card a download control too.
- Lay the cards out in a **centered** grid that keeps partial rows centered (flexbox with `justify-content:
center` and a comfortable fixed tile width — not so narrow the previews feel squished).
- Include a copyable `<link rel=...>` snippet showing exactly how to wire them into a `<head>`, plus the
  webmanifest reference if one exists.

### 5. Color Palette

- One swatch card per color: a generous color block, then **name, token/variable, hex, RGB**, and a sentence of
  usage. Center the swatch cluster.
- Group: primary brand colors, then neutrals, then semantic/status colors (if the brand has them) clearly marked
  as functional-only.
- **Light/dark behavior in writing**: for each color whose role shifts between modes, say so. Document
  mode-specific values that aren't palette entries (e.g. translucent borders `rgba(255,255,255,0.1)` on dark) in a
  small "mode-specific values" table.
- **Contrast table**: the key foreground/background pairs with their WCAG ratio and pass level (AA / AA-large /
  Fail). Compute real ratios — don't guess. Flag any pair that only passes at large sizes or fails.
- Add a one-click **copy** affordance on hex values (small JS, graceful without it).

### 6. Typography

- Specimen block per family: the family name set in itself at display size, the full CSS font stack in code,
  weights loaded, and where it's used.
- **Type scale as live specimens**: each row shows the actual styled element beside its written spec — size
  (including any `clamp()`), weight, line-height, letter-spacing, usage notes. Use real brand-relevant copy, never
  lorem ipsum.
- State heading-hierarchy rules in writing (one `<h1>`; never skip levels; the eyebrow+title opener if the brand
  uses one).

### 7. Buttons & Links — live demos with written state specs

This section earns the page its keep. Pair each interactive element's **working demo** with a **state-spec list**:

- **Primary button** (plus secondary/ghost if the brand has them): a real `<button>` the reader can hover, focus,
  and press. Beside it, a definition list spelling out every state — _Default_ (background, text, radius, padding,
  weight), _Hover_ (exact change incl. shadow + transition + "no transform" if that's the rule), _Focus-visible_
  (outline color/width/offset, and the dark-mode color if different), _Active_, _Disabled_ — even when a state is
  intentionally unchanged.
- A **static state strip**: the same button shown in forced default / hover / focus / disabled appearance side by
  side, so states survive screenshots and printing.
- **Text links**: a live paragraph with a normal, a visited, and an external link, plus written specs for default,
  hover, **visited**, and focus. If visited is intentionally identical to default, say so — silence reads as an
  omission. Note the external-link convention (new window + `(opens in new window)` in the `aria-label`).

### 8. Cards — if the brand has a card component

If the brand's site uses content/listing cards, document them: render a **live demo of each variant** and pair it
with a state-spec. Cover the shell (radius, padding, background + border per mode, hover treatment — border/shadow
change, and "no transform" if that's the rule) plus any distinguishing parts (top accent bar, media/cover area,
tag pills, footer action row). **Footer links must use the brand's real link treatment** — if the brand's card
links are an icon **plus a text label** in the accent color with a specific hover, reproduce that exactly; don't
reduce them to bare icons. These cards follow the page theme toggle (they're live component demos, not mode-pinned
tiles).

### 9. Form Fields

Live, functional fields styled in the brand: text input, textarea, select, checkbox, radio — whichever the brand
uses. (If the brand hasn't styled selects/radios yet, you may extrapolate them from the existing field tokens and
mark them proposed; drop the label once adopted.) For each:

- Proper `<label>` / `<fieldset>`/`<legend>` associations; placeholder conventions if the brand has them.
- Written specs for default (border, background, text), **focus** (ring/outline/border change), **error** (border
    - message color + how the message is presented via `aria-invalid`/`aria-describedby`/`role="alert"`), and
      **disabled**.
- One field shown statically in its error state with a real validation message.
- A note on light vs dark field treatment (field backgrounds and borders usually differ most between modes).

### 10. Accessibility summary

Short and factual: required contrast ratios, the focus-indicator spec, reduced-motion policy, hidden-region rule
(`aria-hidden` + `inert`), and any brand rules (e.g. "decorative icons always `aria-hidden`"). This is the floor
the receiving developer must not go below.

### Token block + dark-mode contract

If the brand's tokens live in CSS custom properties, end with a single copyable code block of the canonical
`:root` / theme variables — the highest-leverage artifact for the receiving developer. Pair it with a short
**dark-mode contract** in prose: how dark mode is toggled (e.g. a `.dark` class on `<html>`), the exact
`localStorage` key, the `prefers-color-scheme` fallback, and the "apply before first paint" rule. Skip the token
block if the brand doesn't actually use CSS variables — don't manufacture a token system it doesn't have.

## Phase 3 — Light & Dark Mode

Both modes must be **fully designed and individually verified** — dark mode is not an afterthought filter.

- **Page-level toggle** in the nav/masthead: match the brand's own toggle if it has one. An icon-only control
  (e.g. sun/moon) is fine **as long as it carries an `aria-label` that updates with state** ("Switch to dark mode"
  / "Switch to light mode") and reflects state via `aria-pressed`. Toggle a `.dark` class on `<html>`, initialize
  from `prefers-color-scheme`, persist in `localStorage` under the brand's exact key, and apply the saved choice
  _before first paint_ (inline `<head>` script) to avoid a flash. Reusing the brand site's localStorage contract
  lets a visitor's preference carry over.
- **Mode-pinned tiles**: logo tiles, favicon previews, and any "this is how X looks on dark" demos keep fixed
  backgrounds and do **not** respond to the page toggle. The toggle changes the page chrome and the live component
  demos; the comparison tiles always show both worlds at once. (Download controls sit on the card chrome around
  these tiles, so they _do_ follow the toggle — that's correct.)
- **Component demos follow the toggle**: buttons, links, cards, and form fields restyle with the theme, and their
  written specs list both modes' values wherever they differ.
- If the brand is single-mode by design, say so prominently and document only that mode — don't invent a second
  theme.

## Phase 4 — Implementation Standards

- **One file.** All CSS in a `<style>` block, all JS (theme toggle, mobile-nav hamburger, clipboard copy — nothing
  more) in a `<script>` block, vanilla only — no frameworks, no build step. The page must work opened from
  `file://`.
- **Progressive enhancement.** The theme toggle, hex-copy buttons, and asset-download links are enhancements: the
  page must read fully and the downloads must work with JS disabled. Native `<a download>` and `<a href>` handle
  this for free; don't route downloads through JS.
- **Assets**: if the page lives in the brand's repo, reference logo/favicon files by relative path and print those
  paths as canonical. If the page must travel alone, inline SVG logos and base64 the raster favicons — and still
  print the original repo paths. Ask the user which delivery mode only if context doesn't make it obvious.
- **Fonts**: load the brand's webfonts the same way the brand site does (e.g. Google Fonts link with exact
  weights), with the full fallback stack so it degrades offline.
- **Tokens drive the page**: define the brand colors once as CSS custom properties at the top of the `<style>`
  block and consume them everywhere. The stylesheet should read like a token reference. Don't leave dead `//`
  comments in CSS — `//` is not a CSS comment and silently swallows nothing useful; use `/* */`.
- **Semantic HTML**: one `<h1>`, logical heading descent (eyebrows are `<p>`, not headings), `<nav>`, `<main>`,
  `<section>` with headings, real `<button>`/`<a>` elements, labeled form controls.
- **The page meets the standards it preaches**: visible focus indicators on every interactive element, AA contrast
  throughout (including muted/secondary text), a `prefers-reduced-motion` media query disabling transitions,
  `aria-hidden` on decorative SVGs.

### Implementation gotchas (learned the hard way)

- **Icon toggle.** If you swap two inline `<svg>` icons by toggling a `hidden` attribute, set it with
  `el.toggleAttribute('hidden', condition)` — `SVGElement` does **not** reflect the `hidden` IDL property, so
  `svg.hidden = true` silently does nothing and the icon never changes. (HTML elements reflect it; SVG ones don't.)
- **Mobile nav.** The collapsed menu needs both `aria-hidden="true"` and `inert`, toggled together; re-evaluate on
  breakpoint change so the menu never stays inert on desktop or open-but-visible after a resize.
- **Download chips over pinned tiles.** Put the download control on the card's own surface (which follows the
  theme), not floating over the fixed light/dark preview — give it a theme-aware chip so it's legible in both
  modes, and add top padding to compact favicon cards so it clears the preview.
- **`<figure>` margins.** Browser-default `figure` margins (`0 40px`) silently break flex/grid card layouts — zero
  them on the card itself.

## Phase 5 — Polish Pass

Polish is what separates a reference page from a brand artifact. Before calling it done, make a deliberate pass:

- **Cut the slop.** Re-read every sentence of the page's own copy. If it's marketing, aspiration, or filler rather
  than a usage instruction or a brand fact, delete it — the masthead especially attracts a stray "positioning
  statement" it doesn't need. (See Non-Negotiable #3.)
- **Only the brand's treatments.** Confirm nothing on the page uses an effect the brand doesn't — no invented
  gradients, blur, glassmorphism, or animation. If you reached for a flourish to make it feel "premium," remove it.
- **Rhythm**: consistent, generous vertical spacing between sections; aligned, centered card grids; one container
  width used consistently.
- **Specimen quality**: all example copy is real and in the brand's voice. No "Lorem ipsum", no "Button", no "Your
  text here" — use what the brand's components actually say.
- **Tables and spec lists** are typeset, not dumped: monospace hex values, consistent capitalization, units on
  every number.
- **Micro-details**: subtle borders so white/near-white swatches don't bleed into the background; favicon previews
  on both light and dark tiles; smooth (motion-safe) theme transition; sensible `<title>` and meta description.
- **Both-mode sweep**: view the entire page top to bottom in light, then dark. Common bugs: borders vanishing in
  one mode, fixed-tile labels unreadable, code blocks not adapting, shadows invisible on dark, download chips
  illegible on a tile.

## Final Verification Checklist

Work through this explicitly before delivering:

- [ ] The page's copy is reference-only — no marketing/positioning sentences; the masthead is logo + title + date.
- [ ] The page uses **only** treatments the brand actually uses (no invented glassmorphism, gradients, blur, or
      animation).
- [ ] Section headers use the brand's own opener pattern (e.g. eyebrow + title) if it has one; exactly one `<h1>`.
- [ ] Every color shown has name, token, hex, and a written usage sentence; contrast table with computed ratios.
- [ ] Every interactive state (hover, focus, active, visited, disabled, error) is both demonstrable _and_ written
      out with exact values — including states that are intentionally unchanged.
- [ ] Logos: all variants on mode-pinned correct backgrounds, centered grid, file paths, clear space, min size,
      don'ts — plus working download controls (native `<a download>`, on card chrome, work without JS).
- [ ] Favicons: real files at true sizes, centered grid (partial rows centered), `<head>` wiring snippet, download
      controls.
- [ ] Cards documented if the brand has a card component, with footer links in the brand's real link treatment
      (icon + label, brand color, correct hover).
- [ ] Form fields cover what the brand uses; proposed-but-unadopted treatments labeled, adopted ones not.
- [ ] The section nav collapses to an accessible hamburger (both `aria-hidden` and `inert` when closed) on mobile;
      toggle reachable at every width.
- [ ] Light and dark both reviewed end-to-end; toggle persists, respects `prefers-color-scheme`, no flash; the
      sun/moon icon actually swaps (toggleAttribute, not `.hidden`).
- [ ] Page works as a single file with no console errors and no build step; degrades without JS.
- [ ] No invented brand facts — anything proposed rather than sourced is labeled; stale "proposed" labels removed.
- [ ] The handoff test: could a developer build a consistent page using _only_ this file? If any answer requires
      devtools or guessing, write the missing fact into the page.
