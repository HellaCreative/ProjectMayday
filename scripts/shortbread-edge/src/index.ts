import {
  PMTiles,
  ResolvedValueCache,
  type RangeResponse,
  type Source,
} from "pmtiles";

interface Env {
  SHORTBREAD: R2Bucket;
  RELEASE_ID: string;
  ARCHIVE_KEY: string;
  SHORTBREAD_SCHEMA: string;
  SOURCE_UPDATED_AT: string;
  COVERAGE_BOUNDS: string;
  SAMPLE_TILE: string;
  PUBLIC_FALLBACK_ORIGIN: string;
}

const manifestContract = "dirt.shortbread-manifest.v1";
const tileContentType = "application/vnd.mapbox-vector-tile";
const directoryCache = new ResolvedValueCache(256);
const archives = new Map<string, PMTiles>();

class R2ArchiveSource implements Source {
  constructor(
    private readonly bucket: R2Bucket,
    private readonly objectKey: string,
  ) {}

  getKey(): string {
    return `r2://${this.objectKey}`;
  }

  async getBytes(
    offset: number,
    length: number,
    _signal?: AbortSignal,
    _etag?: string,
  ): Promise<RangeResponse> {
    const object = await this.bucket.get(this.objectKey, {
      range: { offset, length },
    });
    if (!object) {
      throw new Error(`Shortbread archive not found: ${this.objectKey}`);
    }
    return {
      data: await object.arrayBuffer(),
      etag: object.httpEtag,
      cacheControl: object.httpMetadata?.cacheControl,
      expires: object.httpMetadata?.cacheExpiry?.toUTCString(),
    };
  }
}

function archiveFor(env: Env): PMTiles {
  const key = env.ARCHIVE_KEY;
  const existing = archives.get(key);
  if (existing) return existing;
  const archive = new PMTiles(
    new R2ArchiveSource(env.SHORTBREAD, key),
    directoryCache,
  );
  archives.set(key, archive);
  return archive;
}

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, If-None-Match",
  };
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: {
      ...corsHeaders(),
      "Cache-Control": status === 200 ? "public, max-age=60" : "no-store",
    },
  });
}

function parseBounds(raw: string): [number, number, number, number] {
  const values = raw.split(",").map(Number);
  if (values.length !== 4 || values.some((value) => !Number.isFinite(value))) {
    throw new Error("COVERAGE_BOUNDS must contain four comma-separated numbers");
  }
  return values as [number, number, number, number];
}

function parseTile(raw: string): [number, number, number] {
  const values = raw.split("/").map(Number);
  if (values.length !== 3 || values.some((value) => !Number.isInteger(value))) {
    throw new Error("SAMPLE_TILE must use z/x/y");
  }
  return values as [number, number, number];
}

function parseTilePath(
  pathname: string,
  releaseID: string,
): [number, number, number] | undefined {
  const escapedRelease = releaseID.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = pathname.match(
    new RegExp(
      `^/shortbread/v1/releases/${escapedRelease}/tiles/(\\d+)/(\\d+)/(\\d+)\\.mvt$`,
    ),
  );
  if (!match) return undefined;
  const z = Number(match[1]);
  const x = Number(match[2]);
  const y = Number(match[3]);
  if (z < 0 || z > 14 || x < 0 || y < 0 || x >= 2 ** z || y >= 2 ** z) {
    return undefined;
  }
  return [z, x, y];
}

function manifest(requestURL: URL, env: Env): Record<string, unknown> {
  const tileRoot = `${requestURL.origin}/shortbread/v1/releases/${env.RELEASE_ID}/tiles`;
  return {
    contract: manifestContract,
    releaseID: env.RELEASE_ID,
    shortbreadSchema: env.SHORTBREAD_SCHEMA,
    sourceUpdatedAt: env.SOURCE_UPDATED_AT,
    cacheNamespace: "shortbread-v1",
    minZoom: 0,
    maxZoom: 14,
    bounds: parseBounds(env.COVERAGE_BOUNDS),
    tileTemplate: `${tileRoot}/{z}/{x}/{y}.mvt`,
    sampleTile: `${tileRoot}/${env.SAMPLE_TILE}.mvt`,
    attribution:
      "© OpenStreetMap contributors · Shortbread vector tile schema",
  };
}

async function serveFromPublicFallback(
  tile: [number, number, number],
  env: Env,
): Promise<Response> {
  const [z, x, y] = tile;
  const origin = env.PUBLIC_FALLBACK_ORIGIN.replace(/\/$/, "");
  const response = await fetch(`${origin}/${z}/${x}/${y}.mvt`, {
    headers: { Accept: tileContentType },
  });
  if (!response.ok || !response.body) {
    return new Response(null, { status: response.status || 502 });
  }
  return new Response(response.body, {
    status: 200,
    headers: {
      ...corsHeaders(),
      "Content-Type": tileContentType,
      "Cache-Control": "public, max-age=3600, s-maxage=86400",
      "X-Dirt-Shortbread-Release": env.RELEASE_ID,
      "X-Dirt-Shortbread-Source": "public-fallback",
    },
  });
}

async function serveTile(
  request: Request,
  tile: [number, number, number],
  env: Env,
  context: ExecutionContext,
): Promise<Response> {
  const edgeCache = await caches.open("dirt-shortbread-v1");
  const cached = await edgeCache.match(request);
  if (cached) return cached;

  const [z, x, y] = tile;
  const result = await archiveFor(env).getZxy(z, x, y, request.signal);
  const response = result
    ? new Response(result.data, {
        headers: {
          ...corsHeaders(),
          "Content-Type": tileContentType,
          "Cache-Control": "public, max-age=31536000, immutable",
          "X-Dirt-Shortbread-Release": env.RELEASE_ID,
          "X-Dirt-Shortbread-Source": "r2",
        },
      })
    : await serveFromPublicFallback(tile, env);

  if (response.ok) {
    context.waitUntil(edgeCache.put(request, response.clone()));
  }
  return response;
}

async function health(env: Env): Promise<Response> {
  try {
    const object = await env.SHORTBREAD.head(env.ARCHIVE_KEY);
    if (!object) throw new Error("archive missing");
    const [z, x, y] = parseTile(env.SAMPLE_TILE);
    const sample = await archiveFor(env).getZxy(z, x, y);
    if (!sample || sample.data.byteLength === 0) throw new Error("sample tile missing");
    return json({
      ok: true,
      contract: manifestContract,
      releaseID: env.RELEASE_ID,
      archiveBytes: object.size,
      sampleBytes: sample.data.byteLength,
    });
  } catch (error) {
    return json(
      {
        ok: false,
        contract: manifestContract,
        releaseID: env.RELEASE_ID,
        reason: error instanceof Error ? error.message : "unknown",
      },
      503,
    );
  }
}

export default {
  async fetch(request: Request, env: Env, context: ExecutionContext): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", { status: 405 });
    }

    const url = new URL(request.url);
    if (url.pathname === "/shortbread/v1/manifest.json") {
      return json(manifest(url, env));
    }
    if (url.pathname === "/shortbread/v1/health") {
      return health(env);
    }
    const tile = parseTilePath(url.pathname, env.RELEASE_ID);
    if (tile) {
      const response = await serveTile(request, tile, env, context);
      return request.method === "HEAD"
        ? new Response(null, { status: response.status, headers: response.headers })
        : response;
    }
    return new Response("Not found", { status: 404, headers: corsHeaders() });
  },
};
