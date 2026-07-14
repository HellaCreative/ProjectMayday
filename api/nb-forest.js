// New Brunswick Forest Roads (unmaintained forest access)
// Catalogue: https://open.canada.ca/data/en/dataset/68cee0f3-39fe-10ef-20b0-b8cc51b2a5e8
// Live API:  https://gnb.socrata.com/resource/udwq-sw5i.geojson
//
// Coverage: New Brunswick only. Published via Open Canada because that portal
// aggregates federal + provincial open data — this specific dataset is GNB.

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    return res.status(200).end();
  }

  try {
    const { bbox, limit } = req.query;
    const max = Math.min(Number(limit) || 3000, 5000);

    // Quick reject if viewport clearly outside NB
    // NB approx: west -69.1, south 44.5, east -63.7, north 48.1
    if (bbox) {
      const parts = bbox.split(',').map(Number);
      if (parts.length === 4 && parts.every((n) => Number.isFinite(n))) {
        const [south, west, north, east] = parts;
        const overlapsNB = !(east < -69.1 || west > -63.7 || north < 44.5 || south > 48.1);
        if (!overlapsNB) {
          return res.status(200).json({
            type: 'FeatureCollection',
            features: [],
            meta: {
              dataset: 'NB Forest Roads',
              coverage: 'New Brunswick only',
              note: 'Viewport outside NB — no features'
            }
          });
        }
      }
    }

    let url = `https://gnb.socrata.com/resource/udwq-sw5i.geojson?$limit=${max}`;

    if (bbox) {
      const parts = bbox.split(',').map(Number);
      if (parts.length === 4 && parts.every((n) => Number.isFinite(n))) {
        const [south, west, north, east] = parts;
        // Socrata: within_box(col, north, west, south, east)
        const where = `within_box(the_geom,${north},${west},${south},${east})`;
        url += `&$where=${encodeURIComponent(where)}`;
      }
    }

    console.log('NB Forest Roads:', url);

    const response = await fetch(url, {
      headers: { 'User-Agent': 'DIRT-Trail-Finder/1.0', Accept: 'application/json' }
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);

    const data = await response.json();
    const features = (data.features || []).map((f, i) => ({
      type: 'Feature',
      id: f.properties?.objectid || `nbf-${i}`,
      geometry: f.geometry,
      properties: {
        id: f.properties?.objectid || `nbf-${i}`,
        trailType: 'service',
        highway: 'forest_road',
        name: 'Forest Road',
        roadclass: 'Unmaintained forest access',
        source: 'nb-forest',
        accessStatus: 'unknown',
        accessDetail: 'NB forest road (not DTI-maintained)'
      }
    }));

    return res.status(200).json({
      type: 'FeatureCollection',
      features,
      meta: {
        dataset: 'Forest Roads (New Brunswick)',
        datasetUrl: 'https://open.canada.ca/data/en/dataset/68cee0f3-39fe-10ef-20b0-b8cc51b2a5e8',
        coverage: 'New Brunswick',
        note: 'Unmaintained forest access on crown/private land'
      }
    });
  } catch (error) {
    console.error('NB forest roads error:', error);
    return res.status(500).json({
      error: error.message,
      message: 'Failed to fetch NB Forest Roads'
    });
  }
}
