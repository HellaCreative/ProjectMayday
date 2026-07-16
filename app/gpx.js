(function (global) {
  "use strict";

  const EARTH_RADIUS_M = 6371008.8;

  function number(value) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }

  function distanceMeters(a, b) {
    const lat1 = a.lat * Math.PI / 180;
    const lat2 = b.lat * Math.PI / 180;
    const dLat = (b.lat - a.lat) * Math.PI / 180;
    const dLon = (b.lon - a.lon) * Math.PI / 180;
    const sinLat = Math.sin(dLat / 2);
    const sinLon = Math.sin(dLon / 2);
    const h = sinLat * sinLat + Math.cos(lat1) * Math.cos(lat2) * sinLon * sinLon;
    return 2 * EARTH_RADIUS_M * Math.atan2(Math.sqrt(h), Math.sqrt(Math.max(0, 1 - h)));
  }

  function pointFromElement(element) {
    if (!element) return null;
    const lat = number(element.getAttribute("lat"));
    const lon = number(element.getAttribute("lon"));
    if (lat === null || lon === null || Math.abs(lat) > 90 || Math.abs(lon) > 180) return null;
    return {
      lat,
      lon,
      ele: number(element.querySelector(":scope > ele")?.textContent),
      time: element.querySelector(":scope > time")?.textContent?.trim() || null
    };
  }

  function childText(element, selector) {
    return element?.querySelector(selector)?.textContent?.trim() || "";
  }

  function parseGpx(xmlText, fallbackName) {
    if (typeof DOMParser === "undefined") throw new Error("GPX parsing is unavailable in this browser.");
    const text = String(xmlText || "").replace(/^\uFEFF/, "").trim();
    if (!text) throw new Error("The selected file is empty.");
    const document = new DOMParser().parseFromString(text, "application/xml");
    if (document.querySelector("parsererror")) throw new Error("The selected file is not valid GPX.");
    const root = document.documentElement;
    if (!root || root.localName.toLowerCase() !== "gpx") throw new Error("The selected file is not a GPX file.");

    const tracks = Array.from(document.querySelectorAll("trk")).map((track, index) => {
      const segments = Array.from(track.querySelectorAll(":scope > trkseg"))
        .map((segment) => Array.from(segment.querySelectorAll(":scope > trkpt")).map(pointFromElement).filter(Boolean))
        .filter((segment) => segment.length >= 2);
      return {
        name: childText(track, ":scope > name") || `Track ${index + 1}`,
        segments
      };
    }).filter((track) => track.segments.length);

    let name = childText(document, "metadata > name") || fallbackName || "Imported GPX track";
    let segments = tracks.flatMap((track) => track.segments);
    if (tracks.length) name = tracks[0].name || name;

    if (!segments.length) {
      const routes = Array.from(document.querySelectorAll("rte")).map((route, index) => ({
        name: childText(route, ":scope > name") || `Route ${index + 1}`,
        segments: [Array.from(route.querySelectorAll(":scope > rtept")).map(pointFromElement).filter(Boolean)]
      })).filter((route) => route.segments[0].length >= 2);
      if (routes.length) {
        name = routes[0].name || name;
        segments = routes.flatMap((route) => route.segments);
      }
    }

    if (!segments.length) throw new Error("No track or route with at least two points was found.");
    const points = [];
    segments.forEach((segment, segmentIndex) => {
      segment.forEach((point, pointIndex) => {
        if (segmentIndex > 0 && pointIndex === 0) points.push(null);
        points.push(point);
      });
    });
    return summarize({ name: String(name).trim() || "Imported GPX track", points });
  }

  function summarize(track) {
    const points = Array.isArray(track.points) ? track.points.slice() : [];
    let distance = 0;
    const bounds = { minLat: Infinity, minLon: Infinity, maxLat: -Infinity, maxLon: -Infinity };
    let previous = null;
    for (const point of points) {
      if (!point) { previous = null; continue; }
      bounds.minLat = Math.min(bounds.minLat, point.lat);
      bounds.minLon = Math.min(bounds.minLon, point.lon);
      bounds.maxLat = Math.max(bounds.maxLat, point.lat);
      bounds.maxLon = Math.max(bounds.maxLon, point.lon);
      if (previous) distance += distanceMeters(previous, point);
      previous = point;
    }
    return {
      name: track.name || "Imported GPX track",
      points,
      distanceMeters: Math.round(distance),
      bounds: Number.isFinite(bounds.minLat) ? bounds : null,
      pointCount: points.filter(Boolean).length
    };
  }

  function perpendicularDistance(point, start, end) {
    const x = point.lon;
    const y = point.lat;
    const dx = end.lon - start.lon;
    const dy = end.lat - start.lat;
    if (dx === 0 && dy === 0) return Math.hypot(x - start.lon, y - start.lat);
    const t = Math.max(0, Math.min(1, ((x - start.lon) * dx + (y - start.lat) * dy) / (dx * dx + dy * dy)));
    return Math.hypot(x - (start.lon + t * dx), y - (start.lat + t * dy));
  }

  function simplifySegment(points, tolerance) {
    if (points.length <= 2) return points.slice();
    let maxDistance = 0;
    let split = 0;
    for (let i = 1; i < points.length - 1; i += 1) {
      const distance = perpendicularDistance(points[i], points[0], points[points.length - 1]);
      if (distance > maxDistance) { maxDistance = distance; split = i; }
    }
    if (maxDistance > tolerance) {
      return simplifySegment(points.slice(0, split + 1), tolerance).slice(0, -1)
        .concat(simplifySegment(points.slice(split), tolerance));
    }
    return [points[0], points[points.length - 1]];
  }

  function simplify(track, maxPoints = 80) {
    const points = track.points || [];
    const segments = [];
    let current = [];
    for (const point of points) {
      if (point) current.push(point);
      else if (current.length) { segments.push(current); current = []; }
    }
    if (current.length) segments.push(current);
    const all = segments.flat();
    if (all.length <= maxPoints) return all;
    let tolerance = 0.00001;
    let result = all;
    for (let attempt = 0; attempt < 14 && result.length > maxPoints; attempt += 1) {
      result = segments.flatMap((segment) => simplifySegment(segment, tolerance));
      tolerance *= 1.8;
    }
    return result;
  }

  function toGeoJson(track) {
    const coordinates = [];
    const lines = [];
    let line = [];
    for (const point of track.points || []) {
      if (!point) {
        if (line.length >= 2) lines.push(line);
        line = [];
        continue;
      }
      line.push([point.lon, point.lat]);
    }
    if (line.length >= 2) lines.push(line);
    if (!lines.length) return { type: "FeatureCollection", features: [] };
    return {
      type: "FeatureCollection",
      features: [{
        type: "Feature",
        properties: { kind: "imported-track", name: track.name || "Imported GPX track" },
        geometry: lines.length === 1
          ? { type: "LineString", coordinates: lines[0] }
          : { type: "MultiLineString", coordinates: lines }
      }]
    };
  }

  function escapeXml(value) {
    return String(value ?? "").replace(/[<>&'\"]/g, (char) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", "'": "&apos;", '"': "&quot;" }[char]));
  }

  function toGpx(track) {
    const points = track.points || [];
    const segments = [];
    let segment = [];
    for (const point of points) {
      if (!point) {
        if (segment.length >= 2) segments.push(segment);
        segment = [];
        continue;
      }
      segment.push(point);
    }
    if (segment.length >= 2) segments.push(segment);
    const segmentXml = segments.map((part) => {
      const pointXml = part.map((point) => {
        const ele = point.ele == null ? "" : `<ele>${escapeXml(point.ele)}</ele>`;
        const time = point.time ? `<time>${escapeXml(point.time)}</time>` : "";
        return `<trkpt lat="${point.lat}" lon="${point.lon}">${ele}${time}</trkpt>`;
      }).join("");
      return `<trkseg>${pointXml}</trkseg>`;
    }).join("");
    return `<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="DIRT. MAYDAY." xmlns="http://www.topografix.com/GPX/1/1" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd"><trk><name>${escapeXml(track.name || "DIRT. MAYDAY. track")}</name>${segmentXml}</trk></gpx>`;
  }

  global.DirtGpx = { parseGpx, summarize, simplify, toGeoJson, toGpx };
})(window);
