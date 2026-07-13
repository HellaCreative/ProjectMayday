#!/usr/bin/env node

/**
 * DIRT. Data Source Accessibility Tester
 * Tests which trail data sources are accessible and working
 */

const fs = require('fs').promises;

const sources = [
  // National sources
  {
    id: "osm-geofabrik",
    name: "OpenStreetMap via Geofabrik",
    url: "https://download.geofabrik.de/north-america/canada.html",
    testUrl: "https://download.geofabrik.de/north-america/canada-latest.osm.pbf",
    type: "data",
    priority: 1
  },
  {
    id: "nrcan-nrn",
    name: "National Road Network (NRCan)",
    url: "https://open.canada.ca/data/en/dataset/3d282116-e556-400c-9306-ca1a3cada77f",
    type: "catalogue",
    priority: 1
  },
  {
    id: "geo-ca",
    name: "Geo.ca / CanVec",
    url: "https://geo.ca",
    type: "catalogue",
    priority: 2
  },
  {
    id: "statcan-roads",
    name: "Statistics Canada Road Network",
    url: "https://www150.statcan.gc.ca/n1/en/catalogue/92-500-G",
    type: "catalogue",
    priority: 2
  },

  // Provincial - Priority
  {
    id: "bc-data",
    name: "British Columbia Data Catalogue",
    url: "https://catalogue.data.gov.bc.ca",
    testUrl: "https://catalogue.data.gov.bc.ca/api/3/action/package_search?q=forest+service+roads",
    type: "api",
    priority: 1
  },
  {
    id: "alberta-geodiscover",
    name: "Alberta GeoDiscover",
    url: "https://geodiscover.alberta.ca",
    type: "catalogue",
    priority: 1
  },
  {
    id: "ontario-geohub",
    name: "Ontario GeoHub",
    url: "https://geohub.lio.gov.on.ca",
    type: "catalogue",
    priority: 1
  },
  {
    id: "quebec-donnees",
    name: "Données Québec",
    url: "https://www.donneesquebec.ca",
    type: "catalogue",
    priority: 1
  },
  {
    id: "ns-opendata",
    name: "Nova Scotia Open Data / GeoNOVA",
    url: "https://data.novascotia.ca",
    testUrl: "https://data.novascotia.ca/api/views/metadata/v1",
    type: "api",
    priority: 1
  },

  // Provincial - Secondary
  {
    id: "nb-geonb",
    name: "New Brunswick GeoNB",
    url: "https://geonb.snb.ca",
    type: "catalogue",
    priority: 2
  },
  {
    id: "mb-geoportal",
    name: "Manitoba Geoportal",
    url: "https://mli2.gov.mb.ca",
    type: "catalogue",
    priority: 2
  },
  {
    id: "sk-geohub",
    name: "Saskatchewan GeoHub",
    url: "https://www.saskatchewan.ca/geohub",
    type: "catalogue",
    priority: 2
  },
  {
    id: "nl-geoportal",
    name: "Newfoundland and Labrador Geoportal",
    url: "https://www.gov.nl.ca/ecc/maps",
    type: "catalogue",
    priority: 2
  },
  {
    id: "pei-opendata",
    name: "Prince Edward Island Open Data",
    url: "https://data.princeedwardisland.ca",
    type: "catalogue",
    priority: 2
  },
  {
    id: "yukon-opendata",
    name: "Yukon Open Data",
    url: "https://open.yukon.ca",
    type: "catalogue",
    priority: 2
  },
  {
    id: "nwt-opendata",
    name: "Northwest Territories Spatial Data",
    url: "https://www.nwtgeomatics.ca",
    type: "catalogue",
    priority: 3
  },
  {
    id: "nunavut-geoportal",
    name: "Nunavut Geoportal",
    url: "https://nunavutgeoportal.ca",
    type: "catalogue",
    priority: 3
  },

  // GPX Sources
  {
    id: "graveltravel",
    name: "GravelTravel.ca",
    url: "https://graveltravel.ca",
    type: "gpx",
    priority: 1
  },
  {
    id: "trans-canada-trail",
    name: "Trans Canada Trail",
    url: "https://tctrail.ca",
    type: "gpx",
    priority: 2
  }
];

async function testSource(source) {
  const testUrl = source.testUrl || source.url;
  
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000); // 10s timeout
    
    const response = await fetch(testUrl, {
      method: 'HEAD',
      signal: controller.signal,
      redirect: 'follow'
    });
    
    clearTimeout(timeout);
    
    return {
      id: source.id,
      name: source.name,
      url: source.url,
      testUrl: testUrl,
      status: response.ok ? 'accessible' : 'error',
      statusCode: response.status,
      contentType: response.headers.get('content-type'),
      priority: source.priority,
      type: source.type
    };
  } catch (error) {
    // Try GET as fallback if HEAD fails
    try {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 10000);
      
      const response = await fetch(testUrl, {
        method: 'GET',
        signal: controller.signal,
        redirect: 'follow'
      });
      
      clearTimeout(timeout);
      
      return {
        id: source.id,
        name: source.name,
        url: source.url,
        testUrl: testUrl,
        status: response.ok ? 'accessible' : 'error',
        statusCode: response.status,
        contentType: response.headers.get('content-type'),
        priority: source.priority,
        type: source.type,
        note: 'HEAD failed, GET succeeded'
      };
    } catch (error2) {
      return {
        id: source.id,
        name: source.name,
        url: source.url,
        testUrl: testUrl,
        status: 'failed',
        error: error2.message,
        priority: source.priority,
        type: source.type
      };
    }
  }
}

async function runTests() {
  console.log('🧪 DIRT. Data Source Accessibility Test\n');
  console.log(`Testing ${sources.length} sources...\n`);
  
  const results = [];
  
  // Test all sources
  for (const source of sources) {
    process.stdout.write(`Testing ${source.name}... `);
    const result = await testSource(source);
    results.push(result);
    
    if (result.status === 'accessible') {
      console.log('✅ accessible');
    } else if (result.status === 'error') {
      console.log(`⚠️  HTTP ${result.statusCode}`);
    } else {
      console.log(`❌ ${result.error}`);
    }
  }
  
  console.log('\n' + '='.repeat(80) + '\n');
  
  // Summary by priority
  const priority1 = results.filter(r => r.priority === 1);
  const priority1Accessible = priority1.filter(r => r.status === 'accessible');
  
  console.log('📊 PRIORITY 1 SOURCES (OSM, NRN, BC, AB, ON, QC, NS, GravelTravel)');
  console.log(`   ${priority1Accessible.length}/${priority1.length} accessible\n`);
  
  priority1.forEach(r => {
    const icon = r.status === 'accessible' ? '✅' : '❌';
    console.log(`   ${icon} ${r.name}`);
    if (r.status !== 'accessible') {
      console.log(`      ${r.error || `HTTP ${r.statusCode}`}`);
    }
  });
  
  console.log('\n' + '-'.repeat(80) + '\n');
  
  // Working sources
  const accessible = results.filter(r => r.status === 'accessible');
  console.log(`✅ ACCESSIBLE SOURCES (${accessible.length}/${results.length}):\n`);
  
  accessible.forEach(r => {
    console.log(`   • ${r.name}`);
    console.log(`     URL: ${r.url}`);
    console.log(`     Type: ${r.type}`);
    if (r.contentType) {
      console.log(`     Content-Type: ${r.contentType}`);
    }
    console.log('');
  });
  
  console.log('-'.repeat(80) + '\n');
  
  // Failed sources
  const failed = results.filter(r => r.status !== 'accessible');
  if (failed.length > 0) {
    console.log(`❌ FAILED SOURCES (${failed.length}/${results.length}):\n`);
    
    failed.forEach(r => {
      console.log(`   • ${r.name}`);
      console.log(`     URL: ${r.url}`);
      console.log(`     Error: ${r.error || `HTTP ${r.statusCode}`}`);
      console.log('');
    });
  }
  
  // Export results as JSON
  const outputPath = './test-results.json';
  await fs.writeFile(outputPath, JSON.stringify(results, null, 2));
  console.log(`\n💾 Full results saved to ${outputPath}`);
  
  // Summary
  console.log('\n' + '='.repeat(80));
  console.log('\n🎯 RECOMMENDATIONS:\n');
  
  const workingP1 = priority1.filter(r => r.status === 'accessible');
  if (workingP1.length >= 5) {
    console.log('   ✅ You have enough Priority 1 sources to build a solid initial map!');
    console.log('   📍 Start with these working sources:');
    workingP1.forEach(r => console.log(`      • ${r.name}`));
  } else {
    console.log('   ⚠️  Some Priority 1 sources are unavailable.');
    console.log('   📍 Available Priority 1 sources:');
    workingP1.forEach(r => console.log(`      • ${r.name}`));
  }
  
  console.log('\n');
}

// Run tests
runTests().catch(console.error);
