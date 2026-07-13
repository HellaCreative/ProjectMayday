// Vercel serverless function to fetch Nova Scotia trail data
export default async function handler(req, res) {
  // Enable CORS
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    return res.status(200).end();
  }

  try {
    const { bbox } = req.query;
    
    // NS Topographic Database - Roads, Trails and Rails (Road Line Layer)
    const datasetId = 'a6gf-w68e';
    
    let url = `https://data.novascotia.ca/resource/${datasetId}.geojson`;
    
    // Add spatial filter if bbox provided (format: west,south,east,north)
    if (bbox) {
      const [west, south, east, north] = bbox.split(',').map(Number);
      // Socrata uses $where parameter for spatial queries
      // intersects(geometry, 'POLYGON((...))')
      const polygon = `POLYGON((${west} ${south},${east} ${south},${east} ${north},${west} ${north},${west} ${south}))`;
      url += `?$where=intersects(geometry, '${polygon}')`;
    }
    
    // Limit results to prevent overwhelming responses
    const limit = req.query.limit || 5000;
    const separator = url.includes('?') ? '&' : '?';
    url += `${separator}$limit=${limit}`;
    
    console.log('Fetching NS data from:', url);
    
    const response = await fetch(url, {
      headers: {
        'User-Agent': 'DIRT-Trail-Finder/1.0'
      }
    });

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`);
    }

    const data = await response.json();
    
    // Filter for trail-like features only (not paved roads)
    // NS data uses feature codes - we want trails, unpaved roads, resource roads
    const filtered = {
      type: 'FeatureCollection',
      features: data.features ? data.features.filter(feature => {
        const props = feature.properties || {};
        const fcode = props.fcode || '';
        const road_class = props.road_class || '';
        const surface = props.surface || '';
        
        // Include: trails, unpaved roads, resource roads, winter roads
        // Exclude: paved highways, urban streets
        return (
          fcode.includes('TRAIL') ||
          fcode.includes('TRACK') ||
          fcode.includes('RESOURCE') ||
          road_class === 'Resource Road' ||
          road_class === 'Trail' ||
          surface === 'Unpaved' ||
          surface === 'Gravel' ||
          surface === 'Dirt'
        );
      }) : []
    };
    
    console.log(`Filtered ${filtered.features.length} trails from ${data.features?.length || 0} total features`);
    
    return res.status(200).json(filtered);
    
  } catch (error) {
    console.error('NS trails API error:', error);
    return res.status(500).json({ 
      error: error.message,
      message: 'Failed to fetch NS trail data'
    });
  }
}
