---
name: DIRT Route Planner
description: Scoped reference for the implemented map-first route planner.
colors:
  orange: "#FF7A00"
  orangePressed: "#B85C00"
  ink-light: "#16181C"
  muted-light: "#616872"
  rowFill-light: "rgba(255,255,255,0.5)"
rounded:
  chip: "10px"
  control: "12px"
  sheet: "22px"
spacing:
  inner: "10px"
  row: "14px"
---

# Design System: DIRT Route Planner

## Overview

**Creative North Star: "Map-first DIRT"**

This reference covers only `RoutePlannerCard.swift`. Planning controls sit over the map using the existing DIRT materials, system typography, orange accents, and compact rounded controls. The map remains the rider's spatial reference while the form explains the next action.

Implementation authority is `RoutePlannerCard.swift` and `../../DesignSystem/DirtTheme.swift`. Product and routing authority remains [the product and routing source of truth](../../../docs/ROUTING-SOURCE-OF-TRUTH.md). The user-approved baseline for future UI is recorded in [the root design reference](../../../DESIGN.md). This scoped document does not change routing behavior.

**Key Characteristics:**

- Map visible behind system material.
- Four equally weighted icon-and-title planning tabs.
- Adaptive form content with explicit distance units.

The recorded values describe source implementation. Nine focused tests and final simulator/signed iPhone builds passed. Impeccable review disposition: ship for the simplified controls. Maximum-text rows reflow; simulator scrolling at that size remains unverified; no iPad, Android, or physical-device acceptance is claimed. Frontmatter pixel units are portable representations of the corresponding native point values, not a web implementation specification.

## Colors

The existing brand orange marks actions. The appearance-aware deep-orange `action` token marks the selected planning tab and Loop setup controls. Unselected tabs use `muted`; the selected tab gains `rowFill` behind its icon and title.

Frontmatter neutral colors record the light appearance. Native semantic tokens retain their appearance-aware values; do not replace those tokens with these extracted literals in SwiftUI. The material's final color depends on the map beneath it.

## Typography

Use native system type: tab icons use semibold body and tab titles use caption, bold when selected and medium otherwise. Loop control labels use native subheadline; the distance value adds semibold weight and monospaced digits. Setup error copy uses `DirtType.helper`.

**The Readable Tab Rule.** Only planning-tab typography is capped at `xxxLarge`. The visible short label “Plan” retains “Plan a route” as its accessibility name and native large-content viewer label. Every tab exposes selected state. The form remains outside that cap and continues scaling with Dynamic Type.

## Layout

Portrait uses a content-measured bottom sheet: tabs remain anchored above a scrolling planning area, which grows to the existing map-preserving height limit. Sheet content uses the existing row inset and clears the unchanged bottom dock. Top corners follow the sheet radius; bottom corners meet the screen edge.

Tab content has a scaled minimum height starting at 54 points, capped at 76 points. The bar adds five points of padding, with four points between tabs. Titles may occupy two centered lines. These are tab-content measurements, not the total bar height.

Loop groups use 12-point spacing; the compact material control group uses 8-point spacing, 14-point horizontal padding and 6-point vertical padding. Direction, distance, surface and progress rows switch from horizontal to leading-aligned vertical layouts at accessibility text sizes, with four points between stacked items. Menu rows and the slider retain 44-point minimum heights. Existing landscape drawer code remains in place; this reference does not certify landscape rendering.

## Elevation & Depth

The planner sheet uses `DirtTheme.sheetMaterial` (`thinMaterial`) and a semantic hairline. The tab bar and Loop control group use `regularMaterial`; the selected tab uses translucent `rowFill`. Keep native material rendering. The portrait shell suppresses its shadow when it sits behind the dock; otherwise its black shadow has opacity 0.18, radius 14, and vertical offset −2 points.

## Shapes

Use the existing continuous rounded sheet family and compact control shapes. The selected planning tab uses the chip radius inside the control-radius tab container. Form actions continue using the incumbent DIRT button styles.

## Components

The planner presents From here, Loop, Plan, and Saved tabs; compact setup
controls; progress/cancellation; and route review actions. Keep visual layout,
materials, typography, and accessibility in this design reference. Loop logic,
waypoint behavior, route actions, errors, and data policy are defined only in
[the routing source of truth](../../../docs/ROUTING-SOURCE-OF-TRUTH.md).

## Do's and Don'ts

- **Do** preserve native material, semantic theme tokens, and map context.
- **Do** keep complete accessibility labels and explicit distance units.
- **Do** let Loop form controls adapt to larger text independently of tab chrome.
- **Don't** change the existing bottom dock as part of this planner treatment.
- **Don't** treat this scoped visual reference as routing authority or evidence of platform acceptance.
