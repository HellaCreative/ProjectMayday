// Vercel serverless function to proxy Overpass API requests
export default async function handler(req, res) {
  // Enable CORS
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    return res.status(200).end();
  }

  try {
    const { query } = req.query;
    
    if (!query) {
      return res.status(400).json({ error: 'Missing query parameter' });
    }

    // Try multiple Overpass endpoints
    const endpoints = [
      'https://overpass-api.de/api/interpreter',
      'https://overpass.kumi.systems/api/interpreter',
      'https://maps.mail.ru/osm/tools/overpass/api/interpreter'
    ];

    let lastError = null;

    for (const endpoint of endpoints) {
      try {
        const url = `${endpoint}?data=${encodeURIComponent(query)}`;
        console.log(`Trying endpoint: ${endpoint}`);
        
        const response = await fetch(url, {
          method: 'GET',
          headers: {
            'User-Agent': 'DIRT-Trail-Finder/1.0'
          }
        });

        if (!response.ok) {
          lastError = `HTTP ${response.status}`;
          continue;
        }

        const data = await response.json();
        return res.status(200).json(data);
        
      } catch (err) {
        lastError = err.message;
        console.error(`Failed with ${endpoint}:`, err);
        continue;
      }
    }

    throw new Error(lastError || 'All endpoints failed');
    
  } catch (error) {
    console.error('Proxy error:', error);
    return res.status(500).json({ 
      error: error.message,
      message: 'Failed to fetch from Overpass API'
    });
  }
}
