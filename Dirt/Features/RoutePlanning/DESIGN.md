---
name: DIRT Route Planner
description: Scoped reference for the implemented map-first route planner.
colors:
  orange: "#FF7A00"
  orangePressed: "#C25400"
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
  group: "20px"
---

# Design System: DIRT Route Planner

## Overview

**Creative North Star: "Map-first DIRT"**

This reference covers only `RoutePlannerCard.swift`. Planning controls sit over the map using the existing DIRT materials, system typography, orange accents, and compact rounded controls. The map remains the rider's spatial reference while the form explains the next action.

Implementation authority is `RoutePlannerCard.swift` and `../../DesignSystem/DirtTheme.swift`. Product and routing authority remains [the product and routing source of truth](../../../docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md). This document does not establish app-wide rules or change routing behavior.

**Key Characteristics:**

- Map visible behind system material.
- Four equally weighted icon-and-title planning tabs.
- Adaptive form content with explicit distance units.

The recorded values describe source implementation. Final iPhone screenshot confirmation of the last tab-scaling adjustment was pending when this reference was written; no iPad, Android, or physical-device acceptance is claimed. Frontmatter pixel units are portable representations of the corresponding native point values, not a web implementation specification.

## Colors

The existing brand orange marks actions. The deeper `orangePressed` token marks the selected planning tab and Loop setup controls. Unselected tabs use `muted`; the selected tab gains `rowFill` behind its icon and title.

Frontmatter neutral colors record the light appearance. Native semantic tokens retain their appearance-aware values; do not replace those tokens with these extracted literals in SwiftUI. The material's final color depends on the map beneath it.

## Typography

Use native system type: tab icons use semibold body and tab titles use caption, bold when selected and medium otherwise. Form labels use `DirtType.rowTitle`, explanatory copy uses `DirtType.helper`, and the distance value uses a headline with monospaced digits.

**The Readable Tab Rule.** Only planning-tab typography is capped at `xxxLarge`. The visible short label “Plan” retains “Plan a route” as its accessibility name and native large-content viewer label. Every tab exposes selected state. The form remains outside that cap and continues scaling with Dynamic Type.

## Layout

Portrait uses a content-measured bottom sheet: tabs remain anchored above a scrolling planning area, which grows to the existing map-preserving height limit. Sheet content uses the existing row inset and clears the unchanged bottom dock. Top corners follow the sheet radius; bottom corners meet the screen edge.

Tab content has a scaled minimum height starting at 54 points, capped at 76 points. The bar adds five points of padding, with four points between tabs. Titles may occupy two centered lines. These are tab-content measurements, not the total bar height.

Loop setup separates groups with `DirtSpace.group`. Start controls use `ViewThatFits`: “Here” and “Choose on map” sit horizontally when space permits and stack when necessary. Both retain native minimum hit targets of 44 points. Existing landscape drawer code remains in place; this reference does not certify landscape rendering.

## Elevation & Depth

The planner sheet uses `DirtTheme.sheetMaterial` (`thinMaterial`) and a semantic hairline. The tab bar uses `regularMaterial`; the selected tab uses translucent `rowFill`. Keep native material rendering. The portrait shell suppresses its shadow when it sits behind the dock; otherwise its black shadow has opacity 0.18, radius 14, and vertical offset −2 points.

## Shapes

Use the existing continuous rounded sheet family and compact control shapes. The selected planning tab uses the chip radius inside the control-radius tab container. Form actions continue using the incumbent DIRT button styles.

## Components

- **Planning tabs:** From here (`location`), Loop (`arrow.triangle.2.circlepath`), Plan (`point.topleft.down.to.point.bottomright.curvepath`), Saved (`bookmark`). Keep all four visible. Entering Loop confirms replacement when an itinerary or route exists.
- **Loop setup:** choose a start and a map direction. Supporting copy explains that direction guides the ride and is not a required stop. The distance slider spans 50–500 total kilometres in 25-kilometre steps, displays “km”, and exposes an accessibility value in kilometres. Helper copy distinguishes ride length from fuel range and explains that actual distance follows available roads.
- **Loop generation:** Create Loop becomes Find another loop after a summary exists. A start and direction are required. Routing disables setup controls, displays progress, and offers Cancel. Summary and error copy remain inline; generated routes retain the existing stages, statistics, and route actions.
- **Create Return Route:** remains an action for an eligible open itinerary. It adds a route back to the starting point; it is distinct from the dedicated Loop setup.

## Do's and Don'ts

- **Do** preserve native material, semantic theme tokens, and map context.
- **Do** keep complete accessibility labels and explicit distance units.
- **Do** let Loop form controls adapt to larger text independently of tab chrome.
- **Don't** change the existing bottom dock as part of this planner treatment.
- **Don't** treat this scoped visual reference as routing authority or evidence of platform acceptance.
