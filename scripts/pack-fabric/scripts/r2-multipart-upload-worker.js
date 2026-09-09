const CANDIDATE_KEY = /^v4\/candidates\/fabric-v4-[0-9]{8}-[0-9]{2}\/.+/;

function json(value, status = 200) {
  return Response.json(value, { status });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/__health") return json({ ok: true });

    const key = decodeURIComponent(url.pathname.slice(1));
    if (!CANDIDATE_KEY.test(key) || key.includes("..")) {
      return new Response("Candidate key required", { status: 403 });
    }

    const action = url.searchParams.get("action");
    try {
      if (request.method === "POST" && action === "create") {
        const upload = await env.PACKS.createMultipartUpload(key);
        return json({ key: upload.key, uploadId: upload.uploadId });
      }

      const uploadId = url.searchParams.get("uploadId");
      if (!uploadId) return new Response("Missing uploadId", { status: 400 });
      const upload = env.PACKS.resumeMultipartUpload(key, uploadId);

      if (request.method === "PUT" && action === "part") {
        const partNumber = Number(url.searchParams.get("partNumber"));
        if (!Number.isInteger(partNumber) || partNumber < 1 || !request.body) {
          return new Response("Invalid part", { status: 400 });
        }
        return json(await upload.uploadPart(partNumber, request.body));
      }

      if (request.method === "POST" && action === "complete") {
        const body = await request.json();
        if (!Array.isArray(body.parts) || body.parts.length === 0) {
          return new Response("Missing parts", { status: 400 });
        }
        const object = await upload.complete(body.parts);
        return json({ key: object.key, size: object.size, etag: object.httpEtag });
      }

      if (request.method === "DELETE" && action === "abort") {
        await upload.abort();
        return new Response(null, { status: 204 });
      }

      return new Response("Unsupported multipart action", { status: 405 });
    } catch (error) {
      return json({ error: error instanceof Error ? error.message : String(error) }, 500);
    }
  }
};
