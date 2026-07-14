// National Road Network (NRN) — Open Canada / Statistics Canada
// Dataset: https://open.canada.ca/data/en/dataset/3d282116-e556-400c-9306-ca1a3cada77f
// Live service: https://geo.statcan.gc.ca/geo_wa/rest/services/NRN-RRN/nrn_rrn/MapServer
//
// We pull "Resource / Recreation" and "Service Lane" from Local roads layers
// (these are the forestry / service access roads across all provinces).

const NRN_BASE =
  'https://geo.statcan.gc.ca/geo_wa/rest/services/NRN-RRN/nrn_rrn/MapServer';

// Local roads feature layer IDs by province
const LOCAL_ROAD_LAYERS = {
  AB: 76,
  BC: 77,
  MB: 78,
  NB: 79,
  NL: 80,
  NS: 81,
  NT: 82,
  NU: 83,
  ON: 84,
  PE: 85,
  QC: 86,
  SK: 87,
  YT: 88
};

// Rough WGS84 bboxes [west, south, east, north] for layer selection
const PROVINCE_BBOX = {
  BC: [-139.1, 48.2, -114.0, 60.1],
  AB: [-120.1, 48.9, -109.9, 60.1],
  SK: [-110.1, 48.9, -101.3, 60.1],
  MB: [-102.1, 48.9, -88.9, 60.1],
  ON: [-95.2, 41.6, -74.3, 56.9],
  QC: [-79.8, 44.9, -57.0, 62.6],
  NB: [-69.1, 44.5, -63.7, 48.1],
  NS: [-66.5, 43.3, -59.5, 47.1],
  PE: [-64.5, 45.9, -61.9, 47.1],
  NL: [-67.9, 46.5, -52.5, 60.5],
  YT: [-141.1, 59.8, -123.8, 69.7],
  NT: [-136.5, 60.0, -101.9, 78.8],
  NU: [-120.1, 51.5, -60.7, 83.2]
};

function bboxesOverlap(a, b) {
  // a,b = [west,south,east,north]
  return !(a[2] < b[0] || a[0] > b[2] || a[3] < b[1] || a[1] > b[3]);
}

function provincesForBbox(west, south, east, north) {
  const view = [west, south, east, north];
  const hits = Object.entries(PROVINCE_BBOX)
    .filter(([, pb]) => bboxesOverlap(view, pb))
    .map(([code]) => code);
  // Fallback: if somehow none match, try NS (home market)
  return hits.length ? hits : ['NS'];
}

function classifyNrn(roadclass) {
  const rc = (roadclass || '').toLowerCase();
  if (rc.includes('resource') || rc.includes('recreation') || rc.includes('service')) {
    return 'service';
  }
  // Shouldn't appear because we filter the query, but keep safe default
  return 'service';
}

async function queryLayer(layerId, west, south, east, north, limit) {
  const where = encodeURIComponent(
    "roadclass IN ('Resource / Recreation','Service Lane')"
  );
  const geometry = encodeURIComponent(`${west},${south},${east},${north}`);
  const url =
    `${NRN_BASE}/${layerId}/query?where=${where}` +
    `&geometry=${geometry}&geometryType=esriGeometryEnvelope&inSR=4326` +
    `&spatialRel=esriSpatialRelIntersects&outFields=OBJECTID,roadclass,rtename1en,l_stname_c,datasetnam` +
    `&returnGeometry=true&outSR=4326&f=geojson&resultRecordCount=${limit}`;

  const res = await fetch(url, {
    headers: { 'User-Agent': 'DIRT-Trail-Finder/1.0', Accept: 'application/json' }
  });
  if (!res.ok) throw new Error(`Layer ${layerId} HTTP ${res.status}`);
  return res.json();
}

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    return res.status(200).end();
  }

  try {
    const { bbox, limit } = req.query;
    const max = Math.min(Number(limit) || 2500, 4000);

    // App sends south,west,north,east
    let south = 43.3, west = -66.5, north = 47.1, east = -59.5; // NS default
    if (bbox) {
      const parts = bbox.split(',').map(Number);
      if (parts.length === 4 && parts.every((n) => Number.isFinite(n))) {
        [south, west, north, east] = parts;
      }
    }

    const provinces = provincesForBbox(west, south, east, north);
    const perLayer = Math.max(200, Math.floor(max / Math.max(1, provinces.length)));

    console.log('NRN query provinces:', provinces, { south, west, north, east });

    const results = await Promise.allSettled(
      provinces.map((code) =>
        queryLayer(LOCAL_ROAD_LAYERS[code], west, south, east, north, perLayer)
      )
    );

    const features = [];
    for (const r of results) {
      if (r.status !== 'fulfilled' || !r.value?.features) {
        if (r.status === 'rejected') console.warn('NRN layer failed:', r.reason);
        continue;
      }
      for (const f of r.value.features) {
        const props = f.properties || {};
        const roadclass = props.roadclass || '';
        features.push({
          type: 'Feature',
          id: props.OBJECTID != null ? `nrn-${props.OBJECTID}` : `nrn-${features.length}`,
          geometry: f.geometry,
          properties: {
            id: props.OBJECTID,
            roadclass,
            name: props.rtename1en && props.rtename1en !== 'Unknown'
              ? props.rtename1en
              : (props.l_stname_c || 'Resource Road'),
            highway: 'resource_road',
            trailType: classifyNrn(roadclass),
            source: 'canada-open-data',
            dataset: props.datasetnam || 'NRN',
            accessStatus: 'unknown',
            accessDetail: roadclass || 'NRN resource/service'
          }
        });
      }
    }

    console.log(`NRN: ${features.length} resource/service roads from ${provinces.join(',')}`);

    return res.status(200).json({
      type: 'FeatureCollection',
      features: features.slice(0, max),
      meta: {
        dataset: 'National Road Network (NRN)',
        datasetUrl: 'https://open.canada.ca/data/en/dataset/3d282116-e556-400c-9306-ca1a3cada77f',
        filter: "roadclass IN ('Resource / Recreation','Service Lane')",
        provinces,
        coverage: 'Canada (all provinces/territories with NRN local roads)'
      }
    });
  } catch (error) {
    console.error('NRN API error:', error);
    return res.status(500).json({
      error: error.message,
      message: 'Failed to fetch National Road Network data'
    });
  }
}
