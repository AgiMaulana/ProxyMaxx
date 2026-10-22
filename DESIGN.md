# ProxyMaxx design direction

Dial: ENERGY 1 / RHYTHM 2 / MOTION 1

Provenance: this file was authored by the coding agent, transcribed from a brief the
product owner answered (scope, audience, mood). Agent-written direction tends toward
default AI taste, which is the slop antislop filters, so treat this as a first draft you
own and edit. The brief answers are yours; the wording is mine.

## Product

A native HTTP/HTTPS debugging proxy: a SwiftUI macOS app
(`Sources/ProxyMaxxApp`) plus an Android VPN tunnel companion
(`Android/ProxyMaxxVpn`) that carries a device's traffic to the proxy over SOCKS5. No
licence key, no paid tier: every feature is present because it is our own code. The two
apps and the app icon are one product, so they share one identity.

## Audience

Mobile and web developers reading packet-level detail, often with the app open all day
beside a running device. They value density, speed and precision, and they read
decoration as noise.

## Dials

| Dial | Value | Reason |
|---|---|---|
| ENERGY | 1 (calm, tool-like) | It is opened beside other apps and left running; a loud interface competes with the work it exists to serve. |
| RHYTHM | 2 (consistent with a few real breaks) | The shell is deliberately steady (control bar, filter bar, table), while the detail pane, the guides and the Android screen genuinely differ, so uniformity would be a lie. |
| MOTION | 1 (state feedback only) | A debugger is read while traffic moves; motion spends attention that belongs to the data. |

Reading this as: developer tool chrome for engineers reading packet-level detail, in a
platform-native instrument style, dial ENERGY 1 / RHYTHM 2 / MOTION 1.

## Personality

Precise instrument. Says what is true about the machine, says it in the smallest space
that stays readable, and never celebrates a routine finding. Not playful, not stern.
Avoid: onboarding flourishes, encouragement, exclamation marks, celebratory empty
states.

## Color

Two layers, deliberately small.

**Surfaces and text come from the platform, not from us.** Apple system materials and
grays on macOS, Material 3 surface roles on Android. Reason: one identity across two
systems is cheaper to keep correct than a hand-rolled palette, and it follows OS updates
and accessibility settings (increase contrast, reduce transparency) for free.

**One brand accent: indigo `#6366F1` deepening to violet `#7C3AED`.** Reason: the app
icon is the product's face and the in-app accent has to agree with it. It marks the
single most important control (macOS Start/Stop while idle, Android Connect) and
nothing else. Zero accents is sterile; this accent everywhere is slop, so it stays at
one control per screen.

**Semantic data encoding is a separate system, not brand color.** The macOS table colors
methods (GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS, CONNECT) and status classes (2xx,
3xx, 4xx, 5xx) as first-class data, the way a terminal colors them. Recorded tension:
eight method hues exceeds the "2 to 3 core plus 1 accent" budget in R-29. It survives
only because it encodes real data rather than decorating, and because the alternative
(neutral methods, hue only for status) is a behavior change the owner has not approved.
Recommendation on record: reduce method color to neutral plus weight, keep hue for
status. See Open items.

**Contrast rules.** Body text at or above 4.5:1. Non-text graphic elements at or above
3:1. Never place text over the icon gradient: the gradient is brand surface for the icon
only, never a text background, button fill or page background.

**Techniques deliberately not used**, with the reason rather than as a ban list:

| Technique | Decision | Reason |
|---|---|---|
| Background grid, dot pattern, blueprint lines | Not used | The traffic table already provides all the structure the screen needs; a second grid is ornament. |
| Glow, neon, radial orbs | Not used | Nothing on screen needs to appear to emit light. |
| Glassmorphism | Not used | Material and AppKit already express layering; blur would add cost and blur the data. |
| Capsule badges (Beta, New, AI) | Not used | Every status here is real and already shown as data. |
| Shadows beyond system elevation | Not used | Sheets and popovers already read as above the window. |
| Pill radius everywhere | Not used | Radius signals grouping; a single radius would erase that signal. |

## Typography

System stacks only: SF Pro on macOS through SwiftUI's default text styles, Roboto
through Material 3 on Android.

- Reason to refuse a licensed display face: this is a distributed open-source repo, and
  dense tabular data needs the platform's own optical sizing and tabular figures more
  than it needs a signature letterform.
- Monospace is reserved for values the machine authored: HTTP method, status code, header
  names, hex, timings. Real usage today: `.monospacedDigit()` for sizes, times and counts,
  and `.system(.caption, design: .monospaced)` for method, status and headers.
- No large monospace headings, no wide-tracked uppercase section labels. Hierarchy comes
  from size, weight and color.

## Motion (MOTION 1)

Hover, focus and press feedback; table selection; system sheet presentation. No scroll
choreography, no entrance animations, no floating elements.

The one non-decoration exception is genuine status: the small progress spinner shown
while a response is pending (`MainView.statusCell`) and "Waiting for response" in the
detail pane. That is the machine reporting, not the interface performing.

## Composition

**macOS app.** One focal point: the traffic table. Everything above it (control bar,
filter bar) is chrome, and the detail pane defers to it. The real structure is
`HSplitView` over a SwiftUI `Table` with alternating row backgrounds, plus the stale
system-proxy banner, which is allowed to interrupt because it reports that the machine's
networking is currently broken.

**Android app.** One focal point: the connect control, the screen's only action. The
explainer card below it is reference material, written as plain sentences because the
screen exists to explain the tunnel when something is not being captured.

**Platform-native widgets on purpose** (SwiftUI `Table`, `HSplitView`, Material 3
`OutlinedTextField`, Material switches). Reason: the audience already knows how these
behave, including keyboard behavior, so custom chrome would charge a learning cost for
nothing.

## Icon and brand mark

| Decision | Reason |
|---|---|
| Two opposing arrows (request out, response back) | The product's job is bidirectional traffic passed through a proxy, so the mark is that traffic. |
| Arrows rather than a shield or padlock | A padlock describes TLS trust. The app also tunnels, records, filters and (soon) rewrites, so a trust symbol would undersell and misname it. |
| Indigo to violet gradient | It is the single brand accent, matching the Android theme's purple seed (`#6650a4`) and the design skill's tech-professional palette (`#6366F1`, `#8B5CF6`, accent `#06B6D4`). |
| White glyph | The mark must survive 16px and single-color reproduction, so the silhouette carries it, not internal detail. |
| Squircle, 824 of 1024 with radius 185 | Platform convention: an icon that ignores the OS shape looks foreign in the Dock, and the OS scales on this expectation. |
| Gradient dose capped to the icon | R-01 lists blue-to-purple gradients as forbidden by default. Recorded as an owner decision: the owner was asked and explicitly chose this gradient in session, so it is kept as identity, and it appears only in the app icon, never as an in-app background, button fill or text background. Do not re-litigate silently; if you change it, change it on purpose. |

**Measured, not asserted.** Glyph against the brightest background under it: 3.66:1.
Render probes: 3.56:1 (top-left field), 4.36:1 (centre gap), 5.94:1 (bottom-right),
4.80:1 (bottom-left glow). That passes WCAG 1.4.11 for non-text graphics at 3:1, and it
is below the 4.5:1 text threshold, which does not apply because the icon contains no
text. At 16px the two arrows resolve to two bars with offset heads, checked by rendering
the icon at that size rather than assumed.

**Confirmation trail (R-23).** The mark was built only after the owner picked the
approach, the palette and the motif from offered options. The Android adaptive icon
reuses the same glyph inside the 66dp safe circle, so a launcher mask cannot clip the
arrow tips.

**Residual risk, stated honestly.** Indigo and violet are crowded territory for developer
tools. What distinguishes this mark is the arrow motif and the vertical separation between
the two arrows, not the hue.

## Files

- `Resources/icons/AppIcon.svg`, the reviewable master, mirrored by
  `Android/ProxyMaxxVpn/app/src/main/res/drawable/ic_launcher_background.xml` and
  `ic_launcher_foreground.xml`.

## Open items

1. **Method hues (8) exceed the palette budget.** Proposal: neutral methods with weight
   differentiation, hue reserved for status class. Behavior change, needs approval.
2. **Em dash (U+2014) as a null placeholder in the macOS table.** Used where a client app
   or byte size is absent (`MainView.swift`, `clientApp ??`, `sizeText`). R-02 bans that
   character in text. Proposal: a single hyphen or an empty cell.
3. **The icns is not reproducible from the repo.** `AppIcon.icns` was rasterized by a
   script that is not committed, and `qlmanage` cannot rasterize SVG with alpha, so
   re-exporting from `AppIcon.svg` is not a click away. Proposal: commit the rasterizer
   under `Scripts/`.
4. **Theme.** Both apps follow the system appearance (SwiftUI default, Material 3
   `isSystemInDarkTheme` with dynamic color). Reason: this is a companion tool that runs
   beside other apps all day, so matching the host is the strong reason R-21 asks for,
   not a deferral. No in-app toggle is planned.
