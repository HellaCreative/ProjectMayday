// Vercel serverless function: Open Canada / NB Forest Roads (Socrata)
// Dataset: https://open.canada.ca/data/en/dataset/68cee0f3-39fe-10ef-20b0-b8cc51b2a5e8
// Source API: https://gnb.socrata.com/resource/udwq-sw5i.geojson
// Note: This is New Brunswick Forest Roads (crown/private forest access), not national.

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

    // Socrata within_box(col, north, west, south, east)
    let url = `https://gnb.socrata.com/resource/udwq-sw5i.geojson?$limit=${max}`;

    if (bbox) {
      const parts = bbox.split(',').map(Number);
      if (parts.length === 4 && parts.every((n) => Number.isFinite(n))) {
        // App sends south,west,north,east (same as Overpass / NS helper)
        const [south, west, north, east] = parts;
        const where = `within_box(the_geom,${north},${west},${south},${east})`;
        url += `&$where=${encodeURIComponent(where)}`;
      }
    }

    console.log('Fetching Canada/NB forest roads:', url);

    const response = await fetch(url, {
      headers: { 'User-Agent': 'DIRT-Trail-Finder/1.0', Accept: 'application/json' }
    });

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`);
    }

    const data = await response.json();
    const features = (data.features || []).map((f, i) => ({
      type: 'Feature',
      id: f.properties?.objectid || `ca-${i}`,
      geometry: f.geometry,
      properties: {
        ...(f.properties || {}),
        id: f.properties?.objectid || `ca-${i}`,
        trailType: 'service',
        highway: 'forest_road',
        name: f.properties?.name || 'Forest Road',
        source: 'canada-open-data',
        accessStatus: 'unknown',
        accessDetail: 'NB forest access road'
      }
    }));

    console.log(`Canada roads: ${features.length} features`);

    return res.status(200).json({
      type: 'FeatureCollection',
      features,
      meta: {
        dataset: 'NB Forest Roads (Open Canada / GNB)',
        datasetUrl: 'https://open.canada.ca/data/en/dataset/68cee0f3-39fe-10ef-20b0-b8cc51b2a5e8',
        coverage: 'New Brunswick'
      }
    });
  } catch (error) {
    console.error('Canada roads API error:', error);
    return res.status(500).json({
      error: error.message,
      message: 'Failed to fetch Canadian forest road data'
    });
  }
}
