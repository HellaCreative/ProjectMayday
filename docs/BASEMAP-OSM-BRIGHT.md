# Basemap: OSM Bright on Shortbread

Visual-only restyle of `/app/data/shortbread-style.json` (+ matching `tuneShortbreadContrast()` in `app/index.html`) to approximate [OSM Bright](https://github.com/openmaptiles/osm-bright-gl-style) using the existing OSM Shortbread vector tiles (`vector.openstreetmap.org/shortbread_v1`).

## Unchanged (by design)

- Tile source URL and attribution
- Layer IDs, filters, source-layer names, zoom stops, widths
- DIRT overlays (route paint, markers, POI, gov layers)
- All routing / navigation / offline logic

## Mapped

| OSM Bright concept | Shortbread match |
| --- | --- |
| Background `#f8f4f0` | `background` |
| Water / waterways | `ocean`, `water_*`, ferry lines |
| Parks / grass | `land-park-*`, meadow, recreation, golf, playground… |
| Wood / forest | `land-forest-*`, scrub, orchard, vineyard |
| Residential / commercial / industrial landuse | matching `land-*` fills |
| Building fills | `building*` |
| Motorway / trunk / primary / secondary | `highway-motorway|trunk|primary|secondary|tertiary-*` casing+fill |
| Minor streets | unclassified / service / living_street / residential |
| Paths / tracks | footway / path / track / cycleway / bridleway / steps |
| Rail | rail / tram / narrow_gauge… |
| Place / street / water labels | symbol layers by id pattern |

## Could not fully map (schema gaps vs OpenMapTiles OSM Bright)

OpenMapTiles-only concepts with no Shortbread equivalent (or only partial id match):

- Separate `landcover-ice-shelf` / sand subclasses beyond Shortbread land kinds
- US interstate shield artwork from OSM Bright sprites (Shortbread keeps its own shields/sprites)
- OMT `housenumber` layer (Shortbread uses `addresses`)
- Contours / hillshade (neither style’s Shortbread tile set includes them here)
- Some niche site outlines keep generic `#cfcdca` casing rather than OMT-specific tints

Original SVWD03 colour snapshot: `app/data/shortbread-style.svwd03-backup.json`.
