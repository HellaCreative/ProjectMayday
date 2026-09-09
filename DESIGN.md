---
name: DIRT Future UI Baseline
description: User-approved native glass and compact control direction for future UI work.
colors:
  orange: "#FF7A00"
  orangePressed: "#B85C00"
  onOrange: "#16181C"
rounded:
  chip: "10px"
  control: "12px"
  sheet: "22px"
---

# Design System: DIRT

## Overview

**Creative North Star: "Map-first DIRT"**

Richard approved the route planner’s glass surfaces, compact icon-and-title tabs and orange active treatment as the baseline for all future UI work. Preserve this native visual language when adding or revising interfaces. The September 9 visual consistency pass extends this treatment across existing application sheets and shared controls, while preserving established behavior.

Implementation examples live in [RoutePlannerCard.swift](Dirt/Features/RoutePlanning/RoutePlannerCard.swift); shared tokens live in [DirtTheme.swift](Dirt/DesignSystem/DirtTheme.swift). The [scoped planner reference](Dirt/Features/RoutePlanning/DESIGN.md) records its particular layout and behavior. [Product and routing authority](docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md) remains unchanged.

## Colors

Use existing DIRT semantic colors. The approved planning-tab treatment uses appearance-aware deep-orange `action` for selected icons and titles, a light translucent `rowFill` selected surface and muted inactive content. Orange-filled primary actions use dark `onOrange` foreground through the brand button style. Native appearance-aware neutral tokens remain authoritative.

## Typography

Prefer native semantic system type and compact icon-and-title controls. Keep complete accessibility names when visible labels are shortened. Forms must accommodate larger text and reflow where needed. The planner’s `xxxLarge` cap and native large-content viewer are specific to its dense tab chrome; do not impose that cap on future forms.

## Layout

Group related controls clearly, retain map context on map surfaces and use adaptive layouts at accessibility sizes. Carry the approved compact treatment into future work according to the new surface’s task; do not copy the planner’s four-tab arrangement into unrelated features. The existing bottom dock remains unchanged.

## Elevation & Depth

Use native system material rather than simulated glass. The planner demonstrates `thinMaterial` for its map sheet and `regularMaterial` for tab and control groups, with semantic hairlines and translucent selected surfaces. Reuse the shared surface helpers where appropriate.

## Shapes

Continue the shared rounded control and sheet family from `DirtRadius`. Frontmatter pixel values are portable representations of native point values; they do not replace SwiftUI tokens.

## Components

Use compact SF Symbol and title combinations for related navigation choices, clear selected states, native menus for bounded choices and explicit units for measurements. Primary actions should remain easy to identify and activate. Surface-specific behavior belongs in the corresponding feature reference.

## Do's and Don'ts

- **Do** use the approved glass, compact icon-and-title and orange active treatment as the baseline for future UI.
- **Do** preserve native accessibility labels, selected states and adaptive form layouts.
- **Don't** change routing or navigation behavior during visual refinement.
- **Don't** infer platform qualification from design documentation; this iteration is iPhone-only.

### Native implementation addendum — September 9, 2026

Open Terrain now has a native implementation in the local working tree. The approved [HTML and CSS](experiments/ui-directions-20260909/open-terrain.html) and [native/Android contract](docs/OPEN-TERRAIN-NATIVE-AND-ANDROID.md) take precedence over the earlier orange, material and unchanged-dock descriptions above for this replacement. They remain visual authority; the earlier frontmatter is a historical baseline, not an updated native token export. Current implementation boundaries and unresolved differences are recorded in [Open Terrain implementation status](docs/OPEN-TERRAIN-IMPLEMENTATION-STATUS.md). Source implementation does not establish physical White iPhone visual acceptance or Android implementation/acceptance.
