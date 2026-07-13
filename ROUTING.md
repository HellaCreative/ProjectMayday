# DIRT. Routing Architecture

Point-to-point route planning using trail data sources.

## User Goal

**"Click point A, click point B, get a route using available trail data"**

This transforms DIRT from a trail **viewer** into a trail **planner**.

---

## Core Requirements

### User Experience
1. User clicks point A on map
2. User clicks point B on map
3. App calculates best route along available trails
4. Shows route on map with stats (distance, estimated time, difficulty)
5. Optionally: Turn-by-turn guidance or segment list

### Technical Requirements
1. Convert trail data into a **routable network graph**
2. Find trails near point A and B (snap to network)
3. Run routing algorithm (A*, Dijkstra, or similar)
4. Handle disconnected networks (no route found)
5. Consider trail attributes (difficulty, surface, grade)

---

## Architecture Overview

```
┌─────────────────┐
│  Data Sources   │  OSM, NS Open Data, BC Forest Roads, etc.
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Data Ingestion  │  Download, parse, normalize formats
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Graph Builder   │  Convert trails to network graph
└────────┬────────┘   Nodes = intersections, Edges = trail segments
         │
         ▼
┌─────────────────┐
│ Routing Engine  │  A* or Dijkstra pathfinding
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Map Display   │  Show route, stats, turn-by-turn
└─────────────────┘
```

---

## Implementation Phases

### Phase 1: Network Graph Construction ✅ START HERE

**Goal**: Convert trail line data into a routable graph

**What we need**:
- Trail data as GeoJSON LineStrings
- Node extraction (start/end points + intersections)
- Edge creation (trail segments between nodes)
- Edge properties (length, surface, grade, name)

**Output**: 
```javascript
{
  nodes: [
    { id: 'n1', lat: 44.123, lng: -63.456 },
    { id: 'n2', lat: 44.124, lng: -63.457 }
  ],
  edges: [
    { 
      id: 'e1',
      from: 'n1', 
      to: 'n2',
      distance: 150, // meters
      surface: 'gravel',
      grade: 'g3',
      name: 'Forest Service Road 123'
    }
  ]
}
```

**Tools to consider**:
- [Turf.js](https://turfjs.org/) for geometry operations
- Custom graph builder
- Consider [Geograph](https://github.com/davetimmins/Geograph) or similar

---

### Phase 2: Routing Algorithm

**Goal**: Find shortest/best path between two points

**Algorithm options**:

1. **A\* (Recommended)**
   - Fast, optimal
   - Considers heuristic (straight-line distance to goal)
   - Good for geographic networks
   
2. **Dijkstra**
   - Simpler, guaranteed optimal
   - Slower than A* but works
   
3. **Contraction Hierarchies** (Advanced)
   - Pre-processes graph for speed
   - Used by commercial routing engines
   - Overkill for v1

**Libraries**:
- [ngraph.path](https://github.com/anvaka/ngraph.path) - A* in JavaScript
- [Dijkstrajs](https://github.com/tcort/dijkstrajs) - Simple Dijkstra
- Roll your own (educational, good for custom cost functions)

**Cost function considerations**:
- Distance (shortest path)
- Surface preference (avoid difficult terrain)
- Grade preference (avoid G5 if user wants easy)
- Scenic routes (longer but more interesting)

---

### Phase 3: Snap-to-Network

**Goal**: Connect arbitrary map clicks to nearest trail

**Process**:
1. User clicks at (44.123, -63.456)
2. Find nearest node or edge in graph
3. Snap click point to that location
4. Use snapped point as start/end of route

**Implementation**:
- Turf.js `nearestPointOnLine()` for snapping to edges
- Spatial index (R-tree) for fast nearest-neighbor search
- Consider [rbush](https://github.com/mourner/rbush) for spatial indexing

---

### Phase 4: Route Display

**Goal**: Show calculated route on map

**Features**:
- Highlighted route line (different color/width)
- Start/end markers
- Waypoint markers at turns/intersections
- Route stats panel:
  - Total distance
  - Estimated time
  - Surface breakdown (60% gravel, 30% dirt, 10% pavement)
  - Grade breakdown
- Optional: Elevation profile

**MapLibre implementation**:
```javascript
map.addSource('route', {
  type: 'geojson',
  data: routeGeoJSON
});

map.addLayer({
  id: 'route-line',
  type: 'line',
  source: 'route',
  paint: {
    'line-color': '#00ff00',
    'line-width': 6,
    'line-opacity': 0.8
  }
});
```

---

### Phase 5: Advanced Features (Future)

- **Turn-by-turn directions**
- **Alternative routes** (fastest, scenic, easy)
- **Avoid sections** (user can mark trails as closed/blocked)
- **Multi-point routing** (waypoints A → B → C → D)
- **Export GPX** (download route for GPS device)
- **Offline routing** (pre-build graph, run in browser)
- **Community edits** (users report trail conditions)

---

## Technology Stack

### Frontend (Browser)
- **MapLibre GL JS** — Map rendering (already using)
- **Turf.js** — Geospatial calculations
- **ngraph.path or Dijkstrajs** — Routing algorithm
- **RBush** — Spatial indexing for snapping

### Data Processing (Build-time)
- **Node.js** — Download and process trail data
- **GDAL/ogr2ogr** — Convert shapefile/PBF to GeoJSON
- **PostGIS** (optional) — Spatial database for complex queries
- **Tippecanoe** (optional) — Generate vector tiles for performance

### Backend (Future, optional)
- **Node.js + Express** — Route calculation API
- **PostgreSQL + PostGIS** — Store trail network
- **pgRouting** — Server-side routing (very powerful)
- **Redis** — Cache popular routes

---

## Data Structure: Routable Network

### Input: Trail GeoJSON
```json
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "geometry": {
        "type": "LineString",
        "coordinates": [[-63.5, 44.6], [-63.51, 44.61], [-63.52, 44.62]]
      },
      "properties": {
        "name": "Trail 123",
        "surface": "gravel",
        "grade": "g3",
        "source": "openstreetmap"
      }
    }
  ]
}
```

### Output: Graph (Nodes + Edges)
```json
{
  "nodes": {
    "n1": { "lat": 44.6, "lng": -63.5 },
    "n2": { "lat": 44.61, "lng": -63.51 },
    "n3": { "lat": 44.62, "lng": -63.52 }
  },
  "edges": [
    {
      "id": "e1",
      "from": "n1",
      "to": "n2",
      "distance": 1234.5,
      "geometry": [[-63.5, 44.6], [-63.51, 44.61]],
      "properties": {
        "name": "Trail 123",
        "surface": "gravel",
        "grade": "g3"
      }
    },
    {
      "id": "e2",
      "from": "n2",
      "to": "n3",
      "distance": 1234.5,
      "geometry": [[-63.51, 44.61], [-63.52, 44.62]],
      "properties": {
        "name": "Trail 123",
        "surface": "gravel",
        "grade": "g3"
      }
    }
  ]
}
```

---

## Example: Building a Simple Graph

### Step 1: Extract Nodes
```javascript
const nodes = new Map();
let nodeId = 0;

features.forEach(feature => {
  const coords = feature.geometry.coordinates;
  
  // Add start point
  const startKey = `${coords[0][0]},${coords[0][1]}`;
  if (!nodes.has(startKey)) {
    nodes.set(startKey, { 
      id: `n${nodeId++}`, 
      lat: coords[0][1], 
      lng: coords[0][0] 
    });
  }
  
  // Add end point
  const endKey = `${coords[coords.length-1][0]},${coords[coords.length-1][1]}`;
  if (!nodes.has(endKey)) {
    nodes.set(endKey, { 
      id: `n${nodeId++}`, 
      lat: coords[coords.length-1][1], 
      lng: coords[coords.length-1][0] 
    });
  }
});
```

### Step 2: Create Edges
```javascript
const edges = [];

features.forEach(feature => {
  const coords = feature.geometry.coordinates;
  const startKey = `${coords[0][0]},${coords[0][1]}`;
  const endKey = `${coords[coords.length-1][0]},${coords[coords.length-1][1]}`;
  
  const distance = turf.length(feature, { units: 'meters' });
  
  edges.push({
    from: nodes.get(startKey).id,
    to: nodes.get(endKey).id,
    distance: distance,
    geometry: coords,
    properties: feature.properties
  });
});
```

### Step 3: Run A*
```javascript
import createGraph from 'ngraph.graph';
import path from 'ngraph.path';

const graph = createGraph();

// Add edges (ngraph will auto-create nodes)
edges.forEach(edge => {
  graph.addLink(edge.from, edge.to, { 
    weight: edge.distance,
    ...edge 
  });
});

// Find path
const pathFinder = path.aStar(graph, {
  distance(fromNode, toNode, link) {
    return link.data.weight; // Use distance as cost
  },
  heuristic(fromNode, toNode) {
    // Straight-line distance as heuristic
    const from = nodes.get(fromNode.id);
    const to = nodes.get(toNode.id);
    return turf.distance([from.lng, from.lat], [to.lng, to.lat], { units: 'meters' });
  }
});

const route = pathFinder.find('n1', 'n100');
```

---

## Immediate Next Steps

### 1. Visual Test (Now)
- Enhance `sources-test.html` with show/hide toggles ✅ DONE
- Load multiple sources simultaneously
- See what data looks like overlaid
- Identify coverage gaps

### 2. Build Graph Builder (This Week)
- Create `graph-builder.js`
- Ingest GeoJSON from OSM or NS
- Extract nodes and edges
- Export as JSON

### 3. Proof-of-Concept Router (Next Week)
- Integrate ngraph.path
- Build simple UI: click point A, click point B
- Show calculated route
- Display distance/stats

### 4. Iterate on UX
- Add waypoint support
- Improve snapping
- Add alternative routes
- Route preferences (fast, scenic, easy)

---

## Questions to Consider

1. **Client-side or server-side routing?**
   - Client: Faster, works offline, but limited by browser memory
   - Server: Can handle larger datasets, but requires backend

2. **Pre-built graph or build on-demand?**
   - Pre-built: Faster, but requires build step and updates
   - On-demand: More flexible, but slower for large areas

3. **How to handle disconnected networks?**
   - Show "no route found" message
   - Suggest nearest connected trails
   - Allow multi-modal (trail + road)

4. **Route preferences**:
   - Shortest distance?
   - Fastest (consider surface quality)?
   - Easiest (prefer lower grades)?
   - Most scenic (longer, avoid roads)?

---

## Conclusion

**Your vision is clear**: Turn trail data into routes between points.

**Recommended path forward**:
1. ✅ Test sources visually (see what we have)
2. Build graph from one source (start with NS or OSM)
3. Implement basic A* routing
4. Add UI for clicking points and showing routes
5. Iterate on cost function and preferences

This is achievable with client-side JavaScript and doesn't require a complex backend initially. We can start simple and add sophistication over time.

**Ready to start on the graph builder?**
