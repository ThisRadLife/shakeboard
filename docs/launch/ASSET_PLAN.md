# ShakeBoard Public Launch Asset Plan

Status: production plan for the first public open-source release  
Public repository: `github.com/ThisRadLife/shakeboard`  
Launch target: macOS 14 and later  
Asset source of truth: the app UI, this plan, and `docs/launch/brand/shakeboard-icon-1024.png`

## 1. Truth and labeling rules

All public assets must call the product **ShakeBoard**. The shipped app, bundle, workspace, schemes, helper, URL scheme, data directory, and current UI use ShakeBoard. Capture instructions use `SHAKEBOARD_DATA_DIR`; the implemented capture-only debug switches retain their `PERCH_*` names.

The launch claim set is:

- Open source under Apache-2.0, copyright Clay Money Inc.
- Your data stays on your Mac. No account. No telemetry. The only network call is the update check you opt into.
- One full-width strip along the bottom of the screen.
- Clipboard cards for text, highlighted code, links, images, and files.
- A drag shelf for files.
- Reveal by shaking the mouse or pressing Command-Space.
- Multiple paste stacks, ordered multi-select and Send to Stack, and Split into Stack.
- Named, colored pinboards, with Pinned as the first board.
- On-device OCR with Apple Vision.
- Built-in color themes and custom themes.
- A local, read-only, redacted, consent-gated MCP bridge for Claude Code and Codex. It is off by default.
- Quick Look, editing, and transforms for plain text, whitespace, case, JSON, and URL tracking parameters.
- Privacy controls for ignored apps, Hide from AI, and password-manager exclusion.
- A notarized DMG distributed on GitHub Releases.
- Built-in signed updates. Automatic checks are opt-in on first run, with controls in Settings > General.
- Accessibility permission is required for shake detection and ordered paste-stack advancement.

Use the exact label **Coming** for these items everywhere they appear:

- Encrypted backup and sync through a folder, network share, or iCloud Drive.
- Homebrew cask.

Do not imply that the MCP bridge prevents all same-user software from reading local app data. Describe what the implemented bridge does: off by default, local, read-only, redacted, per-client consent-gated, rate-limited, and audited without logging clipboard text or search terms. Do not show real clipboard data, credentials, customer information, email addresses, addresses, or file names in any launch asset.

Publication remains blocked until the shipped app, release artifact, screenshots, and repository agree with the launch facts. The repository is Apache-2.0, copyright Clay Money Inc. (LICENSE and NOTICE), and the ShakeBoard identity rename has landed.

## 2. Asset source classes

- **Real app screenshot with fake seeded data:** capture the real ShakeBoard build. Seed only synthetic data in an isolated directory. Compositing may crop, mask a desktop background, and add a shadow, but may not redraw or alter the app UI.
- **Codex-generated illustration:** brand artwork that explains a concept without pretending to be the app UI. Keep it visually distinct from screenshots.
- **Written copy:** reviewed Markdown or plain text. Product claims must follow Section 1.
- **Code:** small install commands, HTML/CSS, SVG, or capture scripts. Test all commands before publication.

## 3. Brand system and feature illustrations

The visual language is retro 70s/80s skate culture meeting premium macOS. It should feel warm, tactile, and precise, not distressed or cartoonish.

### 3.1 Style guide

**Palette sampled from the approved icon**

| Token | Hex | Use |
|---|---:|---|
| Night Purple | `#60059C` | Primary dark field and deep gradient stop |
| Board Purple | `#9C049D` | Secondary field and large surfaces |
| Hot Magenta | `#DE06A7` | Accent, glow, and active-state callout |
| Sunset Pink | `#BD1D5E` | Warm shadow and secondary accent |
| Wheel Yellow | `#FDD208` | Primary highlight and small CTA accent |
| Sunset Orange | `#F69D02` | Gradient middle and illustration detail |
| Deck Orange | `#F76D01` | Warm edge and motion accent |
| Ink Plum | `#461333` | Text on light art, outlines, and deep shadow |
| Chrome Mid | `#7B7284` | Metal midtone only |
| Chrome Light | `#D9C8B2` | Metal highlight only |
| Cream Highlight | `#F3C75F` | Warm reflected light; never body text |
| White | `#FFFFFF` | Primary text on dark backgrounds |

Use `#0E0715` for website page backgrounds and `#17101F` for elevated website panels. These two web neutrals are supporting colors, not sampled icon colors. Maintain WCAG AA contrast for text and controls.

**Typography**

- Product display: **Cooper Black** where licensed and rasterized into campaign art; fallback **Fraunces 800** for the website and editable source.
- UI and body: `-apple-system`, BlinkMacSystemFont, "SF Pro Text", sans-serif.
- Code: "SFMono-Regular", Consolas, monospace.
- Headlines use short lines, sentence case, and slightly tight tracking. Do not imitate the icon's chunky `SB` lettering for body copy.

**Lighting and composition**

- Dark-first compositions with a soft magenta-purple bloom behind the subject.
- Chrome receives a narrow cream highlight and a plum shadow. Avoid blue tech glows.
- Use one warm key light from the upper left and a restrained magenta rim light from below.
- UI screenshots remain sharp and color-accurate. Place them on a 2-4 degree tilt only in feature illustrations, never in instructional images.
- Motion is a short lateral wobble or card glide. No constant parallax. Provide a still state and respect reduced motion.

**Icon reuse**

- Use the complete icon. Do not detach the clip, letters, trucks, wheels, or board stripes as a logo.
- Keep at least 12.5% of the icon width as clear space.
- Do not place the icon on a competing magenta-to-purple gradient without a cream keyline or dark plate.
- At 64 px and smaller, use the supplied icon without added text, glow, or shadow.
- Use the full 1024 px source for raster exports. Never upscale the 256 px copy.

### 3.2 Illustration inventory

| ID | Name | Purpose | Used in | Format and exact size | Source | Priority |
|---|---|---|---|---|---|---|
| IL-01 | The strip in motion | Explain reveal, mixed history, and the drag shelf in one branded image | README hero, website hero fallback, press | PNG/WebP, 2880x1800; source canvas 2880x1800 | Real app screenshot with fake seeded data, composed over a Codex-generated desktop illustration | P0 |
| IL-02 | Ordered stack path | Show copies entering a stack and leaving in order | README Stacks, website Stacks | PNG/WebP, 2400x1350 | Codex-generated illustration using real card crops; numbered 1-4 | P0 |
| IL-03 | Pinboard fan | Explain one copy belonging to named colored boards | README Pinboards, website Pinboards | PNG/WebP, 2400x1350 | Codex-generated illustration using real board-chip and card crops | P0 |
| IL-04 | Local privacy boundary | Show Mac, local data, password-manager exclusion, redaction, consent, and the read-only MCP path | README Privacy/MCP, website Privacy and AI | SVG plus PNG 2400x1350 | Codex-generated illustration; labels are written copy | P0 |
| IL-05 | OCR lens | Show a copied image becoming searchable text without a cloud path | README OCR, website OCR | PNG/WebP, 2400x1350 | Codex-generated illustration using a real fake-data OCR result | P1 |
| IL-06 | Theme deck | Present six app themes as skateboard-deck colorways without changing the real UI | Website Themes, social posts | PNG/WebP, 2400x1350 | Codex-generated illustration plus real themed strip crops | P1 |
| IL-07 | Backup routes | Preview encrypted folder, network share, and iCloud Drive backup/sync | Roadmap only | SVG plus PNG 1600x900 | Codex-generated illustration, visibly labeled “Coming” | P2 |

## 4. Screenshot production matrix

All screenshots must come from the real app with fake seeded data. Capture on a clean macOS desktop with notifications, personal menu-bar items, mounted volumes, recent files, and user identity hidden. Use a fresh `SHAKEBOARD_DATA_DIR` for every scenario. Final screenshots must show the ShakeBoard UI.

Primary screenshot masters use 2x Retina pixels. Preserve an untouched PNG master, then export WebP derivatives at 85 quality. Do not include a fake cursor unless the frame explains a click target.

| ID | Name | Exact app state to capture | Used in | Format and exact size | Source | Priority |
|---|---|---|---|---|---|---|
| SS-01 | Mixed history strip | Full-width bottom strip open on All. Show a plain-text shipping note, Swift code with real highlighting, a clean HTTPS link, one product-style image, a three-file card, two shelf files, search empty, Pinned chip visible, no selection, gear without warning | README hero/History, website Hero/History, press | PNG master 2880x760; WebP 2400x633 and 1600x422 | Real app screenshot with fake seeded data | P0 |
| SS-02 | Stacks lane | Strip open with the stack lane. Show “Vendor info” Ready at item 2 of 5, “Launch checklist” Collecting, “Invoice 4821” archived, and cards in the selected stack. No real clipboard content | README Stacks, website Stacks | PNG 2880x1000; WebP 2400x833 | Real app screenshot with fake seeded data; use the implemented `stacks` seed as a base | P0 |
| SS-03 | Ordered multi-select | All view with three non-adjacent cards marked 1, 2, 3 in click order. Context menu open on “Send 3 to Stack” with New Stack and one existing fake stack visible | README Stacks detail, docs | PNG 2880x900 | Real app screenshot with fake seeded data; use `picks` as a base | P1 |
| SS-04 | Pinboards | “Gallery addresses” board selected. Show Pinned first, then Gallery addresses and Shopify snippets. Show four synthetic cards in persisted order and one card context menu with Add to Pinboard | README Pinboards, website Pinboards, press | PNG 2880x760; WebP 2400x633 | Real app screenshot with fake seeded data; use `pinboards` seed | P0 |
| SS-05 | Theme grid | Settings > Appearance. Show System plus ten built-in themes, one selected solid theme, and one clearly fake custom theme named “Sunset Deck” with color controls visible | README Themes, website Themes | PNG 2000x1600; WebP 1600x1280 | Real app screenshot with fake seeded preferences | P0 |
| SS-06A | Settings General | General selected. Show launch at login, the "Automatically check for updates" toggle, and the "Check for Updates..." button; no warnings or personal paths | README Permissions/Setup, docs | PNG 2000x1600 | Real app screenshot with isolated preferences | P1 |
| SS-06B | Settings Appearance | Appearance selected with the same state as SS-05 | README Themes | PNG 2000x1600 | Real app screenshot with isolated preferences | P1 |
| SS-06C | Settings Shortcuts | Shortcuts selected. Show Command-Space and an unset optional stack shortcut; no registration errors | README Permissions/FAQ | PNG 2000x1600 | Real app screenshot with isolated preferences | P1 |
| SS-06D | Settings Clipboard | Clipboard selected. Show history enabled, OCR enabled, synthetic retention values, and an empty ignored-app list or generic fake app | README Privacy | PNG 2000x1600 | Real app screenshot with isolated preferences | P1 |
| SS-06E | Settings Shelf & Shake | Shelf & Shake selected. Show shake enabled, Medium sensitivity, calibration control, and healthy Accessibility status | README Permissions, FAQ | PNG 2000x1600 | Real app screenshot with isolated preferences | P1 |
| SS-06F | Settings Privacy & AI | Privacy & AI selected. Master AI switch off in the primary frame; Claude Code and Codex connect controls, hidden-app controls, and empty request log visible | README MCP, website AI/MCP | PNG 2000x1800; WebP 1600x1440 | Real app screenshot with isolated preferences | P0 |
| SS-06G | Settings About | About selected. Show ShakeBoard, semantic version, macOS requirement, Apache-2.0, Clay Money Inc., and source link | Press fact sheet, docs | PNG 2000x1400 | Real app screenshot with isolated preferences | P1 |
| SS-07 | MCP consent panel | Non-activating consent panel asking whether Claude Code may read clipboard history. Show Allow and Don’t Allow, verified-client detail, and no clipboard content | README MCP, website AI/MCP, security docs | PNG 1600x1000; WebP 1200x750 | Real app screenshot with fake client state; use `consent,snapshot` | P0 |
| SS-08 | OCR search | Strip search contains “kiln schedule.” Results include a synthetic photographed note card with OCR match context and no unrelated personal data | README OCR, website OCR | PNG 2880x760; WebP 2400x633 | Real app screenshot with a purpose-made fake image; seed with `ocr` and `PERCH_OCR_SEED` | P0 |
| SS-09 | Split into Stack | Text card contains eight fake glaze names on separate lines. Context menu is open with “Split into Stack (8 lines)” and the “Split into Stack As” submenu visible | README Split, website Stacks detail | PNG 2200x1400; WebP 1600x1018 | Real app screenshot with fake seeded data | P0 |
| SS-10 | Quick Look | Strip remains visible while a synthetic PDF or image is open in ShakeBoard’s non-activating Quick Look panel; no Finder recents or user paths | README Quick Look/Edit, website Work with a copy | PNG 2880x1800; WebP 2400x1500 | Real app screenshot with fake seeded file; use `preview` only as a base and replace the system probe file | P1 |
| SS-11 | Edit and transforms | Code or JSON card in the real editor. A second frame shows the Transform menu with Trim Whitespace, case options, JSON Pretty/Minify, and Strip Tracking Params where applicable | README Edit/Transforms, website Work with a copy | Two PNGs 2200x1400; WebP 1600x1018 each | Real app screenshot with fake seeded data; use `edit` as a base | P1 |
| SS-12 | File drag shelf | Two synthetic files parked on the shelf while one is dragged back toward Finder; strip stays at the bottom | README Drag shelf, website Shelf | PNG 2880x1800; WebP 2400x1500 | Real app screenshot with fake generated files | P1 |

## 5. README package

The README should lead with a visual result, then explain the main workflows. Every feature section gets one image. Keep the first screen useful without requiring the reader to expand a video.

**Tagline:** `Your clipboard, files, and paste stacks. One strip at the bottom of your Mac.`

| ID | Name | Purpose | Where used | Format and exact size or length | Source | Priority |
|---|---|---|---|---|---|---|
| RD-01 | README icon lockup | Establish name and icon | README top | PNG icon at 160x160 rendered from 1024 source; wordmark as live text | Existing icon plus written copy | P0 |
| RD-02 | README hero | Show the real product immediately | Below title/tagline | IL-01, 2880x1800 PNG with 1440x900 display target | Real app screenshot plus illustration | P0 |
| RD-03 | Badge row | Communicate platform, license, release, and CI status without clutter | Under hero | SVG badges, 20-28 px high; labels: macOS 14+, Apache-2.0, latest release, build | Code-generated shields or repository badges | P0 |
| RD-04 | Opening summary | Explain ShakeBoard in one scan | First paragraph | 45-65 words | Written copy | P0 |
| RD-05 | Clipboard history section | Explain card types, search, reveal, paste, and the bottom strip | Feature section 1 | 90-130 words plus SS-01 2400x633 WebP/PNG fallback | Written copy and real app screenshot | P0 |
| RD-06 | Drag shelf section | Explain parking and dragging files without relocation | Feature section 2 | 60-90 words plus SS-12 2400x1500 | Written copy and real app screenshot | P0 |
| RD-07 | Stacks section | Explain collect, Ready, ordered Command-V, multiple stacks, picks, and Split | Feature section 3 | 140-190 words plus IL-02 2400x1350; link SS-03 and SS-09 in details | Written copy, illustration, and real screenshots | P0 |
| RD-08 | Pinboards section | Explain named colored boards and Pinned | Feature section 4 | 70-110 words plus SS-04 2400x633 | Written copy and real app screenshot | P0 |
| RD-09 | OCR section | Explain on-device image text recognition and search | Feature section 5 | 60-90 words plus SS-08 2400x633 | Written copy and real app screenshot | P0 |
| RD-10 | Quick Look, edit, transforms section | Explain Space preview, editing, derived copies, and supported transforms | Feature section 6 | 90-130 words plus SS-11 1600x1018; link SS-10 | Written copy and real app screenshot | P0 |
| RD-11 | Themes section | Explain System, ten solid themes, and custom themes | Feature section 7 | 50-80 words plus SS-05 1600x1280 | Written copy and real app screenshot | P0 |
| RD-12 | Install section | Give release download and planned Homebrew route | Install | 70-110 words; one shell block of 1 line | Written copy and code | P0 |
| RD-13 | Permission section | Explain why Accessibility is requested and what fails without it | First run / permissions | 80-120 words plus SS-06E 1200x960 crop | Written copy and real app screenshot | P0 |
| RD-14 | Privacy section | State that data stays on the Mac, name the opt-in update-check exception, and cover ignored apps, password managers, Hide from AI, and no account/telemetry | Privacy | 130-180 words plus IL-04 2400x1350 | Written copy and illustration | P0 |
| RD-15 | MCP section | Explain setup, five read-only tools, redaction, consent, limits, and audit log | AI access (MCP) | 220-320 words plus SS-07 1200x750 | Written copy, code, and real app screenshot | P0 |
| RD-16 | Coming section | Keep future claims visibly separate | Roadmap | 30-60 words; encrypted backup/sync and Homebrew labeled Coming | Written copy | P0 |
| RD-17 | FAQ | Resolve common install, shortcut, privacy, and AI questions | README FAQ | 6-8 Q&A, 25-70 words each; link to website FAQ for full set | Written copy | P1 |
| RD-18 | Contributing section | Route contributors to setup, tests, issue templates, and screenshot safety | Contributing | 60-100 words and 3-5 links | Written copy | P0 |
| RD-19 | License section | State Apache-2.0 and copyright holder | Final section | 1-2 sentences, under 35 words | Written copy | P0 |

**README opening copy**

> ShakeBoard keeps the things you copy and the files you are moving in one full-width strip at the bottom of your Mac. Search clipboard history, park files, build ordered paste stacks, and pin the things you use every day. Everything stays on your Mac.

**README install copy**

> Download the notarized DMG from GitHub Releases, open it, and drag ShakeBoard to Applications. ShakeBoard requires macOS 14 or later. On first run, macOS asks for Accessibility permission so ShakeBoard can detect a mouse shake and advance paste stacks after Command-V.
>
> **Coming - Homebrew cask**
>
> ```sh
> brew install --cask shakeboard
> ```
>
> **Built-in updates:** ShakeBoard can check for signed updates. On first run it asks, "Check for ShakeBoard updates automatically?" Settings > General includes "Automatically check for updates" and "Check for Updates..."

## 6. GitHub repository assets and metadata

| ID | Name | Purpose | Where used | Format and exact size or length | Source | Priority |
|---|---|---|---|---|---|---|
| GH-01 | Social preview | Make shared repository links recognizable and legible | GitHub repository social preview | PNG, exactly 1280x640, under 1 MB | Codex-generated illustration using the full icon and SS-01 crop | P0 |
| GH-02 | Repository description | Explain the app in search and link previews | GitHub About | Plain text, <=350 characters; target 172 characters | Written copy | P0 |
| GH-03 | Topics | Improve discovery without keyword stuffing | GitHub About | 10 lowercase topics | Written metadata | P0 |
| GH-04 | Repository URL | Canonical public source location | GitHub, README, About UI | `https://github.com/ThisRadLife/shakeboard` | Written metadata | P0 |

**Repository description**

> A macOS clipboard history, drag shelf, paste-stack, and pinboard app. Your data stays on your Mac, with no account or telemetry. Open source, with on-device OCR and an optional read-only MCP bridge for Claude Code and Codex.

**Topics**

`macos`, `swift`, `swiftui`, `clipboard-manager`, `clipboard-history`, `productivity`, `pasteboard`, `mcp`, `local-first`, `open-source`

**Social preview composition**

- Dark `#0E0715` background with a restrained Night Purple to Hot Magenta bloom.
- Icon at 224x224, positioned 72 px from the left and vertically centered.
- “ShakeBoard” in white, 92 px display type. Tagline below in 34 px SF Pro.
- A cropped real strip enters from the lower right. Do not cover the product name.
- Keep all essential content within a centered 1120x520 safe area.

## 7. Motion assets

### 7.1 Demo GIF

| ID | Name | Purpose | Where used | Format and exact size or length | Source | Priority |
|---|---|---|---|---|---|---|
| MO-01 | Core workflow demo | Show the product without sound | README, website, release notes | Animated WebP 1600x900, 12-16 s, <=8 MB; GIF fallback 1200x675, <=12 MB, 15 fps | Screen recording of real app with fake seeded data | P0 |

GIF/WebP sequence:

1. 0:00-0:02 - Clean desktop. Shake cursor side to side; bottom strip appears.
2. 0:02-0:05 - Search “kiln” and show a text card plus an OCR image result.
3. 0:05-0:08 - Command-click three cards; numbered selection shows click order.
4. 0:08-0:11 - Send the three cards to a new stack named “Glaze notes.”
5. 0:11-0:14 - Set the stack Ready; show item 1 of 3 becoming item 2 of 3 after a paste into a synthetic text field.
6. 0:14-0:16 - Return to the strip and hold on the ShakeBoard icon and tagline.

No recorded keystrokes may paste into a real app document. Use a blank temporary TextEdit document with fake content. Provide a static poster frame from 0:05 for reduced-motion contexts.

### 7.2 Launch video storyboard

| ID | Name | Purpose | Where used | Format and exact size or length | Source | Priority |
|---|---|---|---|---|---|---|
| MO-02 | 40-second launch film | Explain the full product in one shareable piece | Website, Product Hunt, GitHub Release, social | H.264 MP4, 3840x2160, 40 s, 30 fps; AAC optional; captions WebVTT; silent-safe | Screen recording of real app with fake seeded data plus Codex-generated title cards | P1 |
| MO-03 | Launch video poster | Avoid autoplay dependency | Website and social | WebP/JPEG, 1920x1080 | Frame from MO-02 | P1 |
| MO-04 | Captions and transcript | Accessibility and silent viewing | Website and video host | WebVTT plus plain text, 90-120 spoken words | Written copy | P1 |

**40-second shot list**

| Time | Picture | On-screen copy / narration |
|---:|---|---|
| 0:00-0:03 | Icon resolves over a dark purple field, then cuts to a clean desktop | “Meet ShakeBoard.” |
| 0:03-0:07 | Mouse shake reveals the full-width strip | “Your clipboard and drag shelf, one shake away.” |
| 0:07-0:12 | Pan across text, highlighted code, link, image, and file cards | “Text, code, links, images, and files stay close.” |
| 0:12-0:16 | Drag two files onto the shelf, then drag one back out | “Park files while you work.” |
| 0:16-0:22 | Select three cards in click order and Send to Stack | “Collect copies. Keep their order.” |
| 0:22-0:26 | A temporary text field receives three ordered pastes; counter advances | “Then paste them with Command-V.” |
| 0:26-0:30 | Show Pinboards chips, then OCR search matching a photographed fake note | “Pin what matters. Search text inside copied images.” |
| 0:30-0:34 | Quick cuts: theme grid, JSON Pretty, Quick Look | “Make it yours. Preview and clean up copies.” |
| 0:34-0:37 | MCP consent panel and local privacy illustration | “AI access is local, read-only, redacted, and off by default.” |
| 0:37-0:40 | Icon, GitHub URL, and Download button | “ShakeBoard. Open source for macOS 14 and later.” |

Use hard cuts and short 160-220 ms card glides. No fast zooms. All meaningful copy must remain visible for at least 1.5 seconds. Export a second version with no music and burned-in captions.

## 8. Website landing page

Deliver a static site in plain HTML and CSS with a small optional vanilla-JavaScript enhancement layer. It must work without JavaScript, use relative paths, and deploy directly to GitHub Pages. It is dark-first, honors `prefers-color-scheme`, disables nonessential animation under `prefers-reduced-motion`, supports keyboard navigation, includes a skip link, uses semantic landmarks, gives every image useful alt text, and maintains WCAG AA contrast. Do not autoplay audio or video.

| ID | Name | Purpose | Where used | Format and exact size or length | Source | Priority |
|---|---|---|---|---|---|---|
| WB-01 | Static landing page | Convert interest into a safe download or source visit | GitHub Pages/custom domain | HTML/CSS, <=90 KB before images; JS <=8 KB optional; responsive 320-2560 px | Code and written copy | P0 |
| WB-02 | Responsive image set | Keep pages sharp and fast | Website feature sections | AVIF/WebP widths 640, 960, 1440, 1920; PNG fallback at 1920 | Real screenshots and illustrations | P0 |
| WB-03 | Website copy deck | Keep all public claims consistent | All landing sections | Plain text/Markdown, 900-1,300 words including FAQ | Written copy below | P0 |
| WB-04 | Download component | Present the DMG and planned routes honestly | Hero and final CTA | HTML/CSS; button min 44x44 CSS px | Code and written copy | P0 |
| WB-05 | Accessibility metadata | Make motion, icons, navigation, and form-free controls understandable | Whole site | HTML attributes, focus styles, alt text, captions | Code and written copy | P0 |

### 8.1 Section order and final draft copy

#### 1. Navigation

Links: `Features`, `Privacy`, `AI access`, `FAQ`, `GitHub`  
Primary action: `Download for macOS`

#### 2. Hero

Eyebrow: `Open source for macOS 14+`

Headline:

> Everything you copy. Everything you are moving. One strip.

Subhead:

> ShakeBoard keeps clipboard history, files, paste stacks, and pinboards at the bottom of your Mac. Shake the mouse or press Command-Space. No account. No telemetry. Your data stays on your Mac.

Actions: `Download the notarized DMG` and `View source on GitHub`

Small note:

> Requires macOS 14 or later. Accessibility permission powers shake detection and ordered paste stacks.

Visual: IL-01 with a descriptive alt text naming the visible card types.

#### 3. Clipboard history

Heading:

> Your clipboard, in reach.

Body:

> Text, highlighted code, links, images, and copied files become clear cards in one full-width strip. Search the history, press Return to paste, or use Shift-Return for plain text. Shake the mouse to reveal it, or open it with Command-Space.

Visual: SS-01.

#### 4. Drag shelf

Heading:

> Put files down without losing your place.

Body:

> Drag files into ShakeBoard while you work, then drag them out to Finder, Terminal, an editor, or another app. ShakeBoard preserves the original. It never relocates it.

Visual: SS-12.

#### 5. Paste stacks

Heading:

> Copy now. Paste in order later.

Body:

> Collect a batch of copies into a stack. When it is ready, each Command-V pastes the next item in order. One stack can collect while another is ready to paste. Select cards in click order and send them together, or split lines, tabs, and comma-separated text into a new stack.

Supporting labels: `Collect`, `Ready to paste`, `Paste again`  
Visual: IL-02 with links to SS-03 and SS-09.

#### 6. Pinboards

Heading:

> Keep the copies you use every day.

Body:

> Make named, colored boards for addresses, replies, code, or anything else. Pinned is the first board. A copy can live on more than one board, and you control its order.

Visual: SS-04.

#### 7. OCR

Heading:

> Search the words inside an image.

Body:

> ShakeBoard uses Apple Vision on your Mac to recognize text in copied and shelved images. Search it, copy it, paste it, or split it into a stack. The image never needs to leave your computer.

Visual: SS-08 or IL-05.

#### 8. Work with a copy

Heading:

> Preview it. Edit it. Clean it up.

Body:

> Press Space for Quick Look. Edit text and code without changing the original card. Turn rich text into plain text, trim whitespace, change case, format or minify JSON, and remove common tracking parameters from links.

Visual: SS-11 with a smaller SS-10 inset.

#### 9. How it works

Heading:

> Three steps. No new system to learn.

Step 1:

> **Reveal.** Shake the mouse or press Command-Space.

Step 2:

> **Choose.** Search, pin, preview, edit, or send cards to a stack.

Step 3:

> **Paste or drag.** Press Return, work through a stack with Command-V, or drag a file back out.

Visual: three still frames from MO-01. On small screens, stack them vertically.

#### 10. Privacy and security

Heading:

> Local by design.

Body:

> ShakeBoard has no account and no telemetry. Clipboard history stays on your Mac. The only network call is the update check you opt into. Password managers are never captured. You can ignore other apps, pause history, clear it, and hide individual cards from AI tools. Files are preserved, not moved.

Supporting note:

> ShakeBoard is open source under Apache-2.0, so its behavior can be inspected and improved in public.

Visual: left half of IL-04.

#### 11. AI and MCP

Heading:

> Useful context, with a gate in front of it.

Body:

> ShakeBoard includes a local MCP bridge for Claude Code and Codex. It is off by default. When enabled, each verified client asks for consent. The tools are read-only. Secrets are redacted before results are returned, hidden cards stay hidden, and requests are logged without clipboard text or search terms.

Detail:

> Redaction is pattern-based and cannot catch every secret. That is why access starts off, asks per client, and can be revoked in Settings.

Actions: `Read the MCP security model` and `View the read-only tools`  
Visual: SS-07 plus the right half of IL-04.

#### 12. Themes

Heading:

> Pick a board that fits your desk.

Body:

> Use System glass, choose one of ten solid color themes, or make your own. Change the background, cards, text, accent, and collecting colors. Updates appear across every open ShakeBoard panel.

Visual: IL-06 or SS-05.

#### 13. Download CTA

Heading:

> Keep your next copy close.

Body:

> Download the notarized DMG from GitHub Releases. ShakeBoard supports macOS 14 and later.

Actions: `Download ShakeBoard` and `Read the source`

Planned install route:

> **Coming - Homebrew cask**
>
> ```sh
> brew install --cask shakeboard
> ```

Roadmap note:

> **Built-in updates:** ShakeBoard can check for signed updates. Automatic checks are opt-in, with "Automatically check for updates" and "Check for Updates..." in Settings > General.
>
> **Coming:** Encrypted backup and sync through a folder, network share, or iCloud Drive.

#### 14. FAQ

**What does ShakeBoard capture?**  
ShakeBoard keeps copied text, highlighted code, links, images, and files. It also provides a separate shelf for files you drag in. Password managers and secure clipboard markers are excluded.

**Where is my data stored?**  
On your Mac, inside ShakeBoard’s local application data. There is no ShakeBoard account, cloud service, or telemetry. Encrypted backup and sync are Coming.

**Why does ShakeBoard need Accessibility permission?**  
Accessibility permission lets ShakeBoard watch global mouse movement for the shake gesture and follow Command-V so a ready paste stack can advance. Clipboard history itself does not require that permission.

**Does ShakeBoard replace Command-V?**  
No. Normal paste works normally. A stack advances only when you explicitly mark it Ready to paste. Collecting copies into another stack does not take over the clipboard.

**What happens if Command-Space already opens Spotlight?**  
Move Spotlight to another shortcut in System Settings, or change ShakeBoard’s shortcut in Settings. ShakeBoard reports shortcut conflicts instead of silently swallowing the key.

**Can ShakeBoard read text in images?**  
Yes. On-device Apple Vision OCR can recognize text in copied and shelved images. You can search the result or turn recognized text into a normal copy. OCR can be turned off.

**Can Claude Code or Codex read my clipboard?**  
Only if you turn on AI access and approve the client. The local MCP tools are read-only, redact known secret patterns, respect hidden apps and cards, and keep a content-free request log. AI access is off by default.

**Is redaction a guarantee that no secret can be returned?**  
No. Pattern-based redaction can miss unfamiliar secrets. Keep AI access off when you do not need it, use Hide from AI for sensitive cards, and exclude sensitive apps.

**Does ShakeBoard upload files or OCR images?**  
No. OCR runs on the Mac. The MCP bridge does not share image pixels or file contents. Shelf file names are excluded from AI search unless you explicitly enable them.

**Can one copy belong to several pinboards?**  
Yes. Adding a copy to another board does not duplicate or change its content. Pinned is the first board and existing pins remain there.

**How do updates work?**  
ShakeBoard can check for signed updates. On first run it asks, "Check for ShakeBoard updates automatically?" You can change "Automatically check for updates" or use "Check for Updates..." in Settings > General. The appcast is fetched over HTTPS, downloads are EdDSA-signed, and system profiling is off. A Homebrew cask is Coming.

**Is ShakeBoard free?**  
ShakeBoard is open-source software under Apache-2.0. There is no paid plan or account. If that changes, the website and repository must say so plainly before launch.

#### 15. Open source

Heading:

> Built in the open.

Body:

> Read the code, report a bug, propose an improvement, or build your own fork. ShakeBoard is licensed under Apache-2.0. Copyright Clay Money Inc.

Actions: `View on GitHub`, `Read CONTRIBUTING`, `Apache-2.0 license`

#### 16. Footer

> ShakeBoard is an open-source macOS app from Clay Money Inc. Local data. No account. No telemetry.

Links: `GitHub`, `Releases`, `Contributing`, `Security`, `License`, `Press kit`  
Copyright: `Copyright 2026 Clay Money Inc.`

## 9. Web icons and share cards

| ID | Name | Purpose | Where used | Format and exact size | Source | Priority |
|---|---|---|---|---|---|---|
| IC-01 | Browser favicon | Identify the site in tabs and bookmarks | Website root | PNG 16x16 and 32x32; ICO containing both sizes | Existing icon, simplified only if legibility testing requires it | P0 |
| IC-02 | Apple touch icon | Home-screen/bookmark presentation | Website root | PNG 180x180, no transparency outside rounded artwork | Existing 1024 icon | P0 |
| IC-03 | Large web app icon | High-density metadata and PWA-compatible surfaces | Website root | PNG 512x512 | Existing 1024 icon | P0 |
| IC-04 | Safari pinned-tab mask | Monochrome recognizable silhouette | Website root | SVG mask, viewBox 0 0 512 512; single black fill | Vector redrawing of the complete board/clip silhouette | P1 |
| IC-05 | Open Graph card | Rich previews for website links | `og:image` | PNG/JPEG exactly 1200x630, <=1 MB | Codex-generated composition using icon and SS-01 | P0 |
| IC-06 | Twitter/X card | Large summary preview | `twitter:image` | PNG/JPEG exactly 1200x630, <=1 MB | Same master as IC-05 with platform-safe crop | P0 |

OG/Twitter copy: headline `Everything you copy. One strip.`; subhead `Open-source clipboard history, drag shelf, paste stacks, and pinboards for macOS.` Keep text inside a centered 1080x510 safe area.

## 10. Press kit

Publish as a versioned ZIP and a browsable folder. Every image gets a short caption and alt text in `README.txt`. Include no source PSD or licensed font files.

| ID | Name | Purpose | Where used | Format and exact size or length | Source | Priority |
|---|---|---|---|---|---|---|
| PR-01 | Icon pack | Give writers approved artwork | Press kit | PNG 16, 32, 64, 128, 256, 512, and 1024 px; original `.icon` source if redistributable | Existing approved icon | P0 |
| PR-02 | Screenshot pack | Make accurate coverage easy | Press kit | ZIP of SS-01, 02, 04, 05, 07, 08, 09, 10 at master PNG sizes plus captions | Real app screenshots with fake seeded data | P0 |
| PR-03 | Brand overview | Prevent incorrect colors and icon treatment | Press kit | PDF 2 pages, US Letter and A4 exports | Written copy and brand samples | P1 |
| PR-04 | Boilerplate | Provide one accurate product paragraph | Press kit, outreach | 70-100 words | Written copy below | P0 |
| PR-05 | Fact sheet | Provide verifiable launch facts | Press kit | PDF 1 page plus Markdown; 300-500 words | Written copy | P0 |
| PR-06 | Press kit archive | One stable download | Website `/press/` and GitHub Release | ZIP, target <=40 MB, SHA-256 published | Code-packaged approved assets | P1 |

**Boilerplate paragraph**

> ShakeBoard is an open-source macOS app that keeps clipboard history, a file drag shelf, paste stacks, and pinboards in one full-width strip at the bottom of the screen. It handles text, highlighted code, links, images, and files; recognizes image text on-device; and includes an optional local MCP bridge for Claude Code and Codex. Your data stays on your Mac. ShakeBoard has no account or telemetry; its only network call is the update check you opt into. It is licensed under Apache-2.0 by Clay Money Inc. and supports macOS 14 and later.

**Fact sheet fields**

- Product: ShakeBoard
- Category: macOS clipboard history and drag shelf
- Developer and copyright: Clay Money Inc.
- Source: `github.com/ThisRadLife/shakeboard`
- License: Apache-2.0
- Platform: macOS 14+
- Price: none; open source
- Distribution: notarized DMG on GitHub Releases
- Updates: built in; automatic checks are opt-in; "Check for Updates..." in Settings > General
- Coming: Homebrew cask, encrypted backup and sync
- Data model: data stays on your Mac; no account; no telemetry
- Permission: Accessibility for shake detection and paste-stack advancement
- Core workflows: history, shelf, stacks, pinboards, OCR, themes, Quick Look, transforms, optional MCP
- Contact: owner must choose before press kit publication

## 11. Release and launch copy

| ID | Name | Purpose | Where used | Format and exact size or length | Source | Priority |
|---|---|---|---|---|---|---|
| LC-01 | Release notes template | Keep every release clear and testable | GitHub Releases | Markdown, 150-500 words per release | Written copy | P0 |
| LC-02 | Show HN post | Invite technical discussion with concrete facts | Hacker News | Title <=80 chars; body 180-280 words | Written copy below | P1 |
| LC-03 | r/macapps post | Introduce the workflow to Mac users | Reddit | Title <=120 chars; body 180-300 words | Written copy below | P1 |
| LC-04 | Product Hunt tagline | Explain the category at a glance | Product Hunt | <=60 characters; target 55 | Written copy below | P1 |
| LC-05 | Product Hunt description | Explain scope and trust model | Product Hunt | 240-400 characters | Written copy below | P1 |
| LC-06 | Product Hunt first comment | Add maker context and invite useful feedback | Product Hunt | 180-260 words | Written copy below | P1 |

### 11.1 Release notes template

```md
# ShakeBoard vX.Y.Z

One sentence about the outcome of this release.

## What changed

- User-visible change and why it matters.
- User-visible change and why it matters.

## Fixed

- Specific bug and the affected workflow.

## Privacy or permission changes

- None. Or describe the exact change, default, and migration.

## Install

Download `ShakeBoard-X.Y.Z.dmg`, open it, and drag ShakeBoard to Applications.
Requires macOS 14 or later. The DMG is notarized by Apple.

## Verify

- SHA-256: `<value>`
- Source tag: `vX.Y.Z`

## Known issues

- Concrete limitation and workaround, if any.
```

Never say “minor fixes” without naming them. Put any new permission, data migration, or MCP exposure change in its own section.

### 11.2 Show HN

Title:

> Show HN: ShakeBoard - local clipboard history and drag shelf for macOS

Body:

> I built ShakeBoard because clipboard history and moving files around were two versions of the same problem: I needed a temporary place for things while I worked.
>
> ShakeBoard is one full-width strip at the bottom of the Mac. It keeps text, highlighted code, links, images, copied files, and files you drag onto its shelf. Shake the mouse or press Command-Space to open it.
>
> The part I use most is paste stacks. You can collect several copies, mark a stack Ready, and then Command-V pastes each item in order. There are also named pinboards, on-device OCR, Quick Look, editing and text transforms, and custom color themes.
>
> Your data stays on your Mac. There is no account or telemetry. The only network call is the update check you opt into. Password managers are excluded. There is an optional local MCP bridge so Claude Code and Codex can search history. It is off by default, read-only, redacts known secret patterns, asks per client, and keeps a content-free request log. Redaction is not a guarantee, so the UI says that plainly.
>
> ShakeBoard supports macOS 14 and later and is open source under Apache-2.0. I would especially value feedback on paste-stack ergonomics, the MCP security model, and building the app on Macs other than mine.
>
> Source and download: https://github.com/ThisRadLife/shakeboard

### 11.3 r/macapps

Title:

> I made ShakeBoard: an open-source clipboard history, drag shelf, and paste-stack app

Body:

> ShakeBoard lives in one strip across the bottom of your Mac. Shake the mouse or press Command-Space and it shows recent text, highlighted code, links, images, copied files, and files you parked on its drag shelf.
>
> You can search history, keep reusable copies in named pinboards, preview with Space, edit or clean up text, and use on-device OCR to search words inside copied images.
>
> Paste stacks are the main difference from a standard clipboard manager. Collect copies into a stack, mark it Ready, and each Command-V pastes the next item in order. You can keep one stack collecting while another is ready, select cards in click order, or split a list into a stack.
>
> Your data stays on your Mac. The app has no account or telemetry, and it does not capture password managers. The only network call is the update check you opt into. An optional read-only MCP bridge for Claude Code and Codex is off by default and asks for consent per client.
>
> It supports macOS 14+, is licensed under Apache-2.0, and the notarized DMG is on GitHub Releases. Built-in signed updates are opt-in, with manual checks in Settings > General. A Homebrew cask is Coming.
>
> I would love to hear what feels clear, what feels busy, and which workflow you would test first.
>
> https://github.com/ThisRadLife/shakeboard

### 11.4 Product Hunt

Tagline:

> Clipboard history and paste stacks for your Mac

Description:

> ShakeBoard keeps clipboard history, a file drag shelf, paste stacks, and pinboards in one strip at the bottom of your Mac. It is open source, keeps your data on your Mac, and includes on-device OCR plus optional read-only MCP access for Claude Code and Codex.

First comment:

> Hi Product Hunt. I made ShakeBoard because I kept losing the temporary things between apps: a copied address, three snippets that had to be pasted in order, or a file I was still dragging between windows.
>
> ShakeBoard puts those things in one full-width strip at the bottom of the Mac. It handles text, highlighted code, links, images, and files. You can build paste stacks, organize reusable copies in pinboards, search text recognized on-device from images, preview with Quick Look, and edit or transform text.
>
> Privacy shaped the app from the start. Your data stays on your Mac. ShakeBoard has no account or telemetry, and never captures password managers. The only network call is the update check you opt into. Its optional MCP bridge for Claude Code and Codex is off by default, read-only, redacts known secret patterns, asks for consent per client, and records requests without recording clipboard text or search terms. Pattern-based redaction can miss things, so the app does not present it as a guarantee.
>
> ShakeBoard supports macOS 14 and later. The source is available under Apache-2.0, and the first release is a notarized DMG on GitHub. I would be grateful for thoughtful bug reports and feedback on the core workflows.

## 12. CONTRIBUTING screenshot guide asset

| ID | Name | Purpose | Where used | Format and exact size or length | Source | Priority |
|---|---|---|---|---|---|---|
| CT-01 | Safe screenshot guide | Let contributors reproduce launch images without exposing real history | `CONTRIBUTING.md` screenshot section | Markdown, 450-700 words plus command blocks | Written copy and code | P0 |
| CT-02 | Fake seed pack | Make mixed-card, OCR, file, list, and JSON captures consistent | `docs/launch/seed/` in the eventual asset PR | PNG/JPEG/TXT/JSON/PDF; each under 2 MB; no real identifiers | Code-generated fake data | P0 |
| CT-03 | Capture manifest | Map environment flags to expected outputs | Contributor docs | YAML or Markdown table, one row per SS asset | Written copy | P1 |

The guide must say:

1. Never launch a branch build against the normal ShakeBoard data directory or a legacy Perch data directory awaiting migration. Never capture the user’s real clipboard history, shelf, settings, file paths, menu bar, Desktop icons, notifications, or account name.
2. Create a short isolated directory because the MCP Unix socket path has a length limit:

   ```sh
   CAPTURE_DIR="$(mktemp -d /tmp/shakeboard-capture.XXXXXX)"
   ```

3. Build outside iCloud, then launch the real app binary with the isolated data directory and only the required debug state:

   ```sh
   env SHAKEBOARD_DATA_DIR="$CAPTURE_DIR" \
     PERCH_DEBUG_SHOW="stacks,strip,snapshot" \
     /tmp/shakeboard-build/Build/Products/Release/ShakeBoard.app/Contents/MacOS/ShakeBoard
   ```

   The seed and debug switches retain their implemented `PERCH_*` names. The data-directory variable and executable path use ShakeBoard.
4. Use only checked-in synthetic seed assets. Good examples are `example.com` links, `555` phone numbers, invented product notes, and files created inside `CAPTURE_DIR`. Do not use a real customer, artist, gallery address, token, repository secret, or current clipboard item.
5. Use the implemented capture states as starting points:

   - `PERCH_DEBUG_SHOW=pinboards,snapshot`
   - `PERCH_DEBUG_SHOW=stacks,strip,snapshot`
   - `PERCH_DEBUG_SHOW=history,picks,snapshot`
   - `PERCH_DEBUG_SHOW=settings,snapshot`
   - `PERCH_DEBUG_SHOW=settings,privacy,snapshot`
   - `PERCH_DEBUG_SHOW=consent,snapshot`
   - `PERCH_DEBUG_SHOW=ocr` with `PERCH_OCR_SEED=/path/to/fake-image.png`
   - `PERCH_DEBUG_SHOW=edit,history,snapshot`
   - `PERCH_DEBUG_SHOW=preview`

6. Inspect every screenshot at 100% before committing it. Search visible text for real names, email addresses, phone numbers, paths beginning with `/Users/`, tokens, API keys, order numbers, and window titles from unrelated apps.
7. Preserve a lossless PNG master. Export web derivatives from that master. Never edit the UI state into a screenshot after capture; reproduce the state in the app and recapture it.
8. Quit the capture build and remove the temporary directory only after the approved masters have been copied out. Do not add an automated cleanup command to a shared script unless it resolves and validates the exact temporary target first.

## 13. Open decisions for the owner

| ID | Decision | Options | Recommendation | Blocks |
|---|---|---|---|---|
| OD-01 | Public domain | `shakeboard.app`, a subdomain of an existing site, or GitHub Pages only | Buy `shakeboard.app` if available; otherwise launch on GitHub Pages and redirect later | Website canonical URL, OG metadata, press kit |
| OD-02 | Launch video | Full MO-02, GIF only, or no motion | Produce the GIF for P0; make the 40-second video P1 if schedule allows | Product Hunt gallery, social posts |
| OD-03 | Price and donations | No price, GitHub Sponsors, one-time support link, or no funding link | Launch with no price and no account; add a support link only after choosing who receives funds | FAQ, footer, Product Hunt |
| OD-04 | Press contact | Named person, role inbox, or GitHub Discussions only | Use a role inbox owned by Clay Money Inc. | Press fact sheet and outreach |
| OD-05 | Support channel | GitHub Issues, Discussions, email, or a mix | Issues for bugs; Discussions for questions and ideas | README, site footer, templates |
| OD-06 | Security reporting | Public issue, private email, or GitHub private vulnerability reporting | Enable GitHub private vulnerability reporting and publish `SECURITY.md` | MCP launch and press kit |
| OD-07 | Analytics | None, privacy-preserving page counts, or standard analytics | None at launch, consistent with the product’s no-telemetry stance | Website implementation and privacy copy |
| OD-08 | Hosting | GitHub Pages from `docs/`, a `gh-pages` branch, or external static host | GitHub Pages with a custom domain when chosen | Deployment workflow |
| OD-09 | Homebrew timing | Day-one cask or visibly Coming | Keep Coming until the cask is accepted and installation is tested on a clean Mac | README/site install copy |
| OD-10 | Sparkle timing | Shipped in 1.0, opt-in | Shipped in 1.0, opt-in | None |
| OD-11 | Backup/sync scope | Backup only first, bidirectional sync, or both | Describe only as Coming until conflict behavior, encryption, recovery, and versioning are specified | Roadmap art and FAQ |
| OD-12 | Release signing identity display | Clay Money Inc. or another legal Developer ID name | Use the exact identity Apple shows and explain any mismatch with the brand | DMG instructions and Gatekeeper screenshots |
| OD-13 | App Store stance | “Not planned,” “not available,” or omit | Say only that GitHub Releases is the current distribution channel | FAQ and press questions |
| OD-14 | Version and launch date | Owner-selected semantic version and date | Use v1.0.0 only after rename, license, packaging, and clean-Mac verification | Every release asset |

## 14. Production checklist, ordered by dependency

1. **Freeze the truthful claim set.** Confirm the feature list, Coming labels, macOS 14 minimum, no-price stance, copyright holder, and Apache-2.0 decision.
2. **Verify the landed identity changes.** Confirm visible UI, bundle metadata, helper names and commands, repository links, license, copyright, and About screen agree on ShakeBoard and Clay Money Inc.
3. **Choose owner decisions that affect URLs and copy.** Decide the domain, press contact, support route, security reporting, hosting, analytics, and launch version/date.
4. **Finish release infrastructure.** Produce a Developer ID signed and notarized app and DMG. Confirm the GitHub Releases path and the HTTPS appcast. Verify EdDSA signatures, the first-run opt-in prompt, automatic checks, and "Check for Updates..." in Settings > General. Keep Homebrew marked Coming until separately verified.
5. **Run a clean-Mac feature and privacy pass.** Verify macOS 14+, first-run Accessibility copy, first-run update opt-in, system profiling off, shortcut conflicts, history types, shelf, stacks, pinboards, OCR, themes, Quick Look, transforms, ignored apps, password-manager exclusion, Hide from AI, MCP-off default, consent, redaction, and audit behavior.
6. **Build the synthetic seed pack.** Create only fake text, code, links, images, OCR notes, JSON, PDFs, and files. Review it for accidental real identifiers or secret-like strings.
7. **Capture real app masters.** Use a fresh `SHAKEBOARD_DATA_DIR` per state and complete SS-01 through SS-12. Inspect every pixel at 100%. Capture only the current ShakeBoard build.
8. **Approve the brand system.** Lock palette, typography licenses, icon clear space, lighting, and reduced-motion behavior before composing illustrations.
9. **Produce P0 illustrations and social cards.** Complete IL-01 through IL-04, GH-01, IC-05, and IC-06 from approved screenshot masters.
10. **Produce icon exports.** Generate and test 16, 32, 180, and 512 px raster icons plus the SVG mask. Check the 16 px favicon on light and dark browser chrome.
11. **Write and assemble the README.** Add the hero, badges, feature sections, install, permissions, privacy, MCP, FAQ, contributing, Coming items, and license. Verify every link from a fresh clone.
12. **Build the static website.** Implement the section order and approved copy in plain HTML/CSS, add responsive images, metadata, skip link, focus states, color-scheme handling, and reduced-motion handling. Test without JavaScript.
13. **Create the safe screenshot contribution guide.** Add CT-01 and the capture manifest in the later documentation PR. Test every example against an isolated directory.
14. **Record motion.** Capture MO-01 first. If approved, record MO-02, captions, transcript, poster, and a silent-safe export from the same fake-data build.
15. **Assemble the press kit.** Export the icon pack, approved screenshot ZIP, boilerplate, fact sheet, captions, and checksums. Add the selected contact.
16. **Prepare release copy.** Fill LC-01 with the actual version, changes, known issues, SHA-256, and tag. Remove placeholders and verify the DMG filename.
17. **Stage launch posts.** Recheck Show HN, r/macapps, and Product Hunt copy against the shipped build. Replace the URL only with the confirmed canonical URL. Describe built-in updates as shipped and opt-in. Do not claim Homebrew or backup/sync has shipped.
18. **Run accessibility and performance checks.** Test keyboard-only navigation, VoiceOver order, alt text, captions, 200% zoom, 320 px width, light/dark preference, reduced motion, and page weight on a slow connection.
19. **Run final legal and security checks.** Confirm Apache-2.0 notices, third-party attributions, font and artwork rights, private vulnerability reporting, no secrets in source or seed assets, and no real clipboard data in images or video.
20. **Dry-run the public path.** From a signed-out browser and a clean macOS account, open the website, follow the release link, download the DMG, verify the checksum and notarization, install, grant Accessibility, open with Command-Space, and complete one fake stack paste.
21. **Publish in dependency order.** GitHub repository and release first, website second, press kit third, then launch posts. Confirm social previews after caches refresh.
22. **Watch the first 48 hours.** Triage install failures, permission confusion, crash reports, security reports, and misleading copy. Update known issues with exact workarounds. Do not silently broaden data collection or AI access while responding to feedback.
