# DIRT iOS — UI & Design

Native chrome tokens and interaction patterns, aligned to the web DIRT Enduro lock. Spec: [WEB-SPEC-FOR-IOS.md](./WEB-SPEC-FOR-IOS.md) §1–2. Source of truth in code: `Dirt/DesignSystem/DirtTheme.swift`.

---

## Tokens (`DirtTheme`)

| Token | Hex / value | Role |
| --- | --- | --- |
| `orange` | `#ff7a00` | Accent, active dock pill, auth/group primary CTAs, destination marker, **dirt route line** |
| `orangeHover` / `orangePressed` | `#e56a00` / `#c25400` | Defined; limited use today |
| `chrome` | `#16181c` | Dock, brand chip, Save CTA, Stop sharing, nav HUD chrome |
| `chromeBorder` | white 12% | Dock / chip / HUD outlines |
| `ink` / `muted` | `#16181c` / `#616872` | Body / secondary |
| `sheet` / `wash` | white 97% / `#f1f2f4` | Sheets + chip idle fill |
| `navGreen` | `#147a56` | **Start / End navigation only** (+ live rider dots) |
| `exportGray` | `#616872` | Export GPX |
| `danger` | `#d83b42` | Errors / clear route / destructive |
| `dirtMix` | `#3a9dff` | Dirt **% stats** + mix bar |
| `pavedMix` | `#fdb003` | Paved **% stats** + mix bar |
| `pavedLine` | `#303a45` | Paved **map** segments |

Layers legend colours (access/gravel/branches/bridge/tunnel/restricted) are inlined in `LayersSheet` to match the web legend hexes.

---

## Typography

Web uses Archivo + Martian Mono. iOS stand-ins in `DirtTheme`:

| Helper | Mapping |
| --- | --- |
| `.dirtUI(_:weight:)` | System UI (Archivo stand-in) |
| `.dirtMono(_:weight:)` | System monospaced (Martian Mono stand-in) |

Density cues: dock labels ~9.5pt heavy + tracking; primary CTAs ~12pt heavy uppercase; invite codes / metrics use mono.

Brand chip: italic black `DIRT` + orange `.` · mono `MAYDAY` wide tracking (`BrandChip`).

No bundled custom fonts in the target today.

---

## Bottom dock

`RootView` dock:

- Chrome background, full width, safe-area aware.
- Four equal tabs: Layers · Profile · Group · Route.
- **Only one tool open at a time** (opening one closes the others) — web parity.
- Active: orange fill + **1px white stroke** (`DirtTheme.orange` + white overlay stroke).
- Route toggles an in-chrome planner card (not a `.sheet`); Layers/Profile/Group use SwiftUI sheets.

Locate control sits in top chrome (circle, chrome fill), not in the dock.

---

## Sheet / card patterns

| Surface | Presentation |
| --- | --- |
| Layers / Profile | `.sheet` medium+large detents |
| Groups | `.sheet` large |
| Route planner | Floating card above dock (`DirtTheme.sheet`, 18pt radius, shadow) |
| Nav HUD | Floating chrome cards above dock while `navigation.phase != .idle` |
| Toasts | Top capsule via `planner.toast` |

Planner handle capsule collapses the card (`isOpen = false`).

---

## CTA colour matrix

| Action | Fill | Notes |
| --- | --- | --- |
| Save route | Chrome black `#16181c` | |
| Export GPX | Gray `#616872` | |
| Start navigation | Green `#147a56` | Only Start (and End navigation) |
| Auth / Create group / Join / Start sharing | Orange `#ff7a00` | Never green |
| Stop sharing | Chrome | |
| Clear route | Text / danger colour | Not a filled CTA |

`DirtCTAStyle` + `DirtChipStyle` encode pressed opacity and active white stroke on chips.

---

## Active-state white strokes

| Element | Stroke |
| --- | --- |
| Active dock tab | 1pt white |
| Active profile chip | white ~90% |
| Brand / locate / HUD | `chromeBorder` (white 12%), not full white |

---

## Matches web

- Token hexes for orange / chrome / nav green / mix colours / danger.
- Dock mutual exclusion + active orange pill + white stroke.
- Route CTA matrix Save / Export / Start.
- Brand chip structure.
- Allow-unknown acknowledgement copy before enabling.
- Groups require account; closing groups resets to list.

---

## Still diverges

| Topic | Divergence |
| --- | --- |
| Fonts | System stand-ins; Archivo/Martian not bundled |
| Shortbread contrast tune | Web post-processes style; iOS does not |
| Layers | Prefs only — no streamed overlays/POIs |
| Route card | Native card vs web DOM planner chrome (layout close, not pixel-identical) |
| Sheets | System SwiftUI sheets vs custom web drawers |
| Debug sheet | Not shipped |
| Map dirt line | Orange (selected-route), same as web selected route — not blue mix |
| Forced light mode | `preferredColorScheme(.light)` |

---

## Starting a new agent on this area

1. Read `DirtTheme.swift` and `RootView.swift` before changing chrome.
2. Skim [WEB-SPEC-FOR-IOS.md](./WEB-SPEC-FOR-IOS.md) §1–2 for locked hexes.
3. **Invariants:** green only for Start/End nav; Save black / Export gray; active dock white stroke; one dock tool at a time; don’t invent a second orange or “success green” for auth.
4. **Open questions:** bundle Archivo/Martian fonts?; dark mode ever, or stay daylight-forced?; pixel audit against web screenshots after TestFlight.
