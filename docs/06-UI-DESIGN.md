# DIRT iOS — UI & Design

Native chrome tokens and interaction patterns, aligned to the Figma screens page (`DIRT.` file, node `40:977` — Map Idle, planner states, navigation, Layers/Profile/Groups). Source of truth in code: `Dirt/DesignSystem/DirtTheme.swift`.

---

## Tokens (`DirtTheme`)

| Token | Hex / value | Role |
| --- | --- | --- |
| `orange` | `#ff7a00` | Accent, active dock pill, auth/group primary CTAs, destination marker |
| `orangeHover` / `orangePressed` | `#e56a00` / `#c25400` | Defined; limited use today |
| `chrome` | `#16181c` | Dock, brand chip, Save CTA, Stop sharing, nav HUD chrome |
| `chromeBorder` | white 12% | Dock / chip / HUD outlines |
| `ink` / `muted` | `#16181c` / `#616872` | Body / secondary |
| `sheet` / `wash` | white 97% / `#f1f2f4` | Sheets + chip idle fill |
| `navGreen` | `#147a56` | **Start navigation only** (+ live rider dots / LIVE badges) |
| `exportGray` | `#616872` | Export GPX |
| `danger` | `#d83b42` | Errors / clear route / destructive |
| `dirtMix` | `#3a9dff` | Dirt **% stats** + mix bar |
| `pavedMix` | `#fdb003` | Paved **% stats** + mix bar |
| `pavedLine` | `#303a45` | Layers/basemap paved overlay (not selected route) |
| `routeAccess` / `routeGravel` / `routeTrack` / `routePaved` / `routeConnector` | `#0a66c2` / `#5d6874` / `#7c3aed` / `#ffb000` / `#d22730` | Selected-route map paint |

Layers legend colours (access/gravel/branches/bridge/tunnel/restricted) are inlined in `LayersSheet`.

---

## Typography

Web uses Archivo + Martian Mono. iOS stand-ins in `DirtTheme`:

| Helper | Mapping |
| --- | --- |
| `.dirtUI(_:weight:)` | System UI (Archivo stand-in) |
| `.dirtMono(_:weight:)` | System monospaced (Martian Mono stand-in) |

Density cues: dock labels ~9.5pt heavy + tracking; primary CTAs ~12pt heavy uppercase; invite codes / metrics use mono.

## Map control stack

Right-edge chrome above the dock / nav HUD:

| Control | Behavior |
| --- | --- |
| **3D / 2D** | Always available on the primary map; toggles basemap pitch (`45°` idle / `55°` while following) |
| **Cues** | Navigation-only. Popover: Junction / Essential or Rally / Everything + independent Audio On/Off (`dirt_cue_mode_v1`, `dirt_cue_audio_v1`) |
| **Compass** | Rose tracks map bearing; tap resets north-up |
| **Rider status** | Always available on the primary map; quick group sharing + Available / Breakdown / Injured / Stuck |
| **Route overview** | Appears beside Recenter only when an actual route polyline is painted |
| **Recenter** | Follow my location (course-up); orange while follow is locked **or while the nav Recenter chip is up** (either control re-locks follow) |

Planning keeps 3D/2D, Compass, Rider Status, and Recenter visible. Cues appears
only after navigation begins; Route Overview hides immediately when no route is
painted.

Idle map top-left holds the brand chip. During navigation the top row is **DIRT.** · turn cue (+ distance) · dark speed pill. Recenter lives on the right control stack.

Brand chip: italic black `DIRT` + orange `.` only (`BrandChip`) — MAYDAY is no longer in the wordmark.

No bundled custom fonts in the target today.

---

## Bottom dock

`RootView` dock (Figma restyle):

- **Floating rounded bar** — chrome fill, 26pt continuous radius, `chromeBorder` stroke, shadow, 8pt horizontal inset above the home indicator (no longer full-bleed).
- Four equal tabs: Layers · Profile · Group · Route.
- **Only one tool open at a time** (opening one closes the others).
- Active: orange fill + **1px white stroke** (`DirtTheme.orange` + white overlay stroke).
- Route toggles an in-chrome planner card (not a `.sheet`); Layers/Profile/Group use SwiftUI sheets.
- Hidden while navigating.

---

## Sheet / card patterns

| Surface | Presentation |
| --- | --- |
| Layers / Profile | `.sheet` medium+large detents |
| Groups | `.sheet` large |
| Route planner | Floating card above dock (`DirtTheme.sheet`, 22pt radius, shadow) |
| Nav chrome | Split top/bottom (see below) while `navigation.phase != .idle` |
| Incident flow | `IncidentFlowOverlay` — scrim + bottom card (report → recovery → confirm) |
| Toasts | Top capsule via `planner.toast` |

### Route planner card (Figma redesign)

- **Orange tab bar** (From here / Plan a route / Saved) with white active pill.
- Mode chips Clean / Balanced / Dirt (active orange). In Plan they edit the selected stage; otherwise the default for new stages.
- **Stage rows**: orange number badge · white km box · blue `% dirt` box · per-stage Allow-unknown mini toggle, with the stage's mode label above the row. >3 stages scrolls.
- Stat chips (KM / %DIRT / %PAVED on `wash`) + blue/yellow mix bar.
- Icon CTAs: SAVE (chrome) · EXPORT GPX (gray) · START (green, play) · red "Clear All" text.
- Helper-text empty states (From-here tap guide, Plan first-pin guide).
- Handle tap **minimizes** to a single orange-outlined tab pill (Figma minimized state); dock Route closes the card entirely.

### Navigation chrome (Figma `50:5240`)

- **Top row**: `DIRT.` brand · centered `NavCueCard` (arrow + maneuver label + **distance to turn**) · dark chrome `NavSpeedPill` (`100` / `km`).
- **Bottom**: inset `NavBottomPanel` (~8pt from sides/bottom) — chrome card with **top radius 16 / bottom radius 29**. Header: surface label + compact **REPORT** (amber/`pavedMix`, ink type) and **END NAVIGATION** (danger). Below: three bordered stat boxes (`km to go` / `travel time` / `elevation:m`).
- **Recenter chip**: orange "Recenter" capsule when the rider pans away; stack recenter also re-locks course-up follow.

---

## CTA colour matrix

| Action | Fill | Notes |
| --- | --- | --- |
| Save route | Chrome black `#16181c` | With save icon |
| Export GPX | Gray `#616872` | With doc icon |
| Start navigation | Green `#147a56` | With play icon — the only green CTA |
| End navigation | Danger `#d83b42` | Capsule with x icon (Figma redesign — was green) |
| Report (nav) | Chrome capsule | Opens incident flow |
| Auth / Create group / Join / Start sharing / Save name / Start trial | Orange `#ff7a00` | Never green |
| Sign out / Stop sharing | Chrome | |
| Clear All | Text / danger colour | Not a filled CTA |

`DirtCTAStyle` + `DirtChipStyle` encode pressed opacity and active white stroke on chips.

---

## Active-state white strokes

| Element | Stroke |
| --- | --- |
| Active dock tab | 1pt white |
| Active profile chip | white ~90% |
| Brand / locate / HUD | `chromeBorder` (white 12%), not full white |

---

## Locked chrome

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
| Shortbread contrast tune | Contrast is baked into `shortbread-style.json` |
| Layers | Prefs only — no streamed overlays/POIs |
| Route card | Native planner card |
| Sheets | System SwiftUI sheets |
| Debug sheet | Not shipped |
| Map dirt line | Per-surface palette (access `#0a66c2`, gravel `#5d6874`, track `#7c3aed`, paved `#ffb000`, connector `#d22730`) — not brand orange; stats mix stays `#3a9dff` / `#fdb003` |
| Forced light mode | `preferredColorScheme(.light)` |

---

## Starting a new agent on this area

1. Read `DirtTheme.swift` and `RootView.swift` before changing chrome.
2. Skim the iOS docs §1–2 for locked hexes.
3. **Invariants:** green only for Start/End nav; Save black / Export gray; active dock white stroke; one dock tool at a time; don’t invent a second orange or “success green” for auth.
4. **Open questions:** bundle Archivo/Martian fonts?; dark mode ever, or stay daylight-forced?; pixel audit after TestFlight.
