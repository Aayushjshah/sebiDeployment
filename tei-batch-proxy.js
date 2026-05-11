const http = require("node:http");
const https = require("node:https");
const tls = require("node:tls");
const { URL } = require("node:url");

const PORT = intEnv("PORT", 8080);
const UPSTREAM_EMBEDDINGS_URL = requiredEnv("UPSTREAM_EMBEDDINGS_URL");
const BATCH_SIZE = intEnv("EMBEDDINGS_BATCH_SIZE", 512);
const UPSTREAM_CONCURRENCY = intEnv("UPSTREAM_CONCURRENCY", 1);
const REQUEST_TIMEOUT_MS = intEnv("REQUEST_TIMEOUT_MS", 1800000);
const MAX_RETRIES = intEnv("MAX_RETRIES", 8);
const RETRY_BASE_MS = intEnv("RETRY_BASE_MS", 1000);
const PROXY_PAYLOAD_LIMIT_BYTES = intEnv("PROXY_PAYLOAD_LIMIT_BYTES", 200000000);

const upstreamUrl = new URL(UPSTREAM_EMBEDDINGS_URL);

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === "GET" && (req.url === "/" || req.url === "/health")) {
      sendJson(res, 200, {
        status: "ok",
        upstream: redactUrl(upstreamUrl),
        batch_size: BATCH_SIZE,
        upstream_concurrency: UPSTREAM_CONCURRENCY,
      });
      return;
    }

    if (req.method !== "POST" || req.url.split("?")[0] !== "/v1/embeddings") {
      sendJson(res, 404, { error: { message: "Not found" } });
      return;
    }

    const rawBody = await readRequestBody(req, PROXY_PAYLOAD_LIMIT_BYTES);
    const requestBody = parseJsonBody(rawBody);
    validateEmbeddingRequest(requestBody);

    const startedAt = Date.now();
    const input = requestBody.input;

    if (!Array.isArray(input)) {
      const upstreamResponse = await postJsonWithRetries(requestBody, req.headers);
      sendJson(res, upstreamResponse.statusCode, upstreamResponse.body);
      logRequest(input === undefined ? 0 : 1, 1, startedAt, upstreamResponse.statusCode);
      return;
    }

    const batches = chunkInputs(input, BATCH_SIZE);
    const batchResults = await mapWithConcurrency(
      batches,
      UPSTREAM_CONCURRENCY,
      async (batch) => {
        const batchBody = { ...requestBody, input: batch.input };
        const upstreamResponse = await postJsonWithRetries(batchBody, req.headers);

        if (upstreamResponse.statusCode < 200 || upstreamResponse.statusCode >= 300) {
          throw httpError(
            upstreamResponse.statusCode,
            upstreamResponse.body,
            `Upstream embedding request failed with ${upstreamResponse.statusCode}`,
          );
        }

        return {
          start: batch.start,
          inputCount: batch.input.length,
          body: upstreamResponse.body,
        };
      },
    );

    const merged = mergeOpenAIEmbeddingResponses(batchResults, requestBody.model);
    sendJson(res, 200, merged);
    logRequest(input.length, batches.length, startedAt, 200);
  } catch (error) {
    const statusCode = error.statusCode || 500;
    sendJson(res, statusCode, {
      error: {
        message: error.publicMessage || error.message || "Embedding proxy error",
        type: error.type || "embedding_proxy_error",
      },
    });
    console.error(`[tei-batch-proxy] ${statusCode} ${error.stack || error.message}`);
  }
});

server.headersTimeout = Math.max(REQUEST_TIMEOUT_MS + 60000, 660000);
server.requestTimeout = Math.max(REQUEST_TIMEOUT_MS + 60000, 660000);
server.listen(PORT, () => {
  console.log(
    `[tei-batch-proxy] listening on :${PORT}; upstream=${redactUrl(upstreamUrl)}; batch_size=${BATCH_SIZE}; concurrency=${UPSTREAM_CONCURRENCY}`,
  );
});

function validateEmbeddingRequest(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw httpError(400, null, "Request body must be a JSON object");
  }
  if (!Object.prototype.hasOwnProperty.call(body, "input")) {
    throw httpError(400, null, "Request body must include input");
  }
  if (Array.isArray(body.input) && body.input.length === 0) {
    throw httpError(400, null, "input array must not be empty");
  }
}

function readRequestBody(req, limitBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let totalBytes = 0;

    req.on("data", (chunk) => {
      totalBytes += chunk.length;
      if (totalBytes > limitBytes) {
        reject(httpError(413, null, `Payload exceeds ${limitBytes} bytes`));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });

    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function parseJsonBody(rawBody) {
  try {
    return JSON.parse(rawBody || "{}");
  } catch (error) {
    throw httpError(400, null, "Invalid JSON request body");
  }
}

function chunkInputs(input, batchSize) {
  const chunks = [];
  for (let start = 0; start < input.length; start += batchSize) {
    chunks.push({ start, input: input.slice(start, start + batchSize) });
  }
  return chunks;
}

async function mapWithConcurrency(items, concurrency, worker) {
  const results = new Array(items.length);
  let nextIndex = 0;
  const workerCount = Math.min(Math.max(concurrency, 1), items.length);

  async function runWorker() {
    while (nextIndex < items.length) {
      const currentIndex = nextIndex;
      nextIndex += 1;
      results[currentIndex] = await worker(items[currentIndex], currentIndex);
    }
  }

  await Promise.all(Array.from({ length: workerCount }, runWorker));
  return results;
}

async function postJsonWithRetries(body, incomingHeaders) {
  let lastError;

  for (let attempt = 0; attempt <= MAX_RETRIES; attempt += 1) {
    try {
      const response = await postJson(body, incomingHeaders);
      if (!shouldRetryResponse(response) || attempt === MAX_RETRIES) {
        return response;
      }

      const retryDelay = retryDelayMs(attempt, response.headers);
      console.warn(
        `[tei-batch-proxy] upstream ${response.statusCode}; retrying in ${retryDelay}ms (attempt ${attempt + 1}/${MAX_RETRIES})`,
      );
      await sleep(retryDelay);
    } catch (error) {
      lastError = error;
      if (attempt === MAX_RETRIES || !shouldRetryError(error)) {
        throw error;
      }

      const retryDelay = retryDelayMs(attempt);
      console.warn(
        `[tei-batch-proxy] upstream error ${error.message}; retrying in ${retryDelay}ms (attempt ${attempt + 1}/${MAX_RETRIES})`,
      );
      await sleep(retryDelay);
    }
  }

  throw lastError || new Error("Upstream request failed");
}

async function postJson(body, incomingHeaders) {
  const bodyBuffer = Buffer.from(JSON.stringify(body), "utf8");
  const headers = upstreamHeaders(incomingHeaders, bodyBuffer.length);
  const response = await requestBuffer(upstreamUrl, "POST", headers, bodyBuffer, REQUEST_TIMEOUT_MS);
  const parsedBody = parseUpstreamBody(response.body);
  return {
    statusCode: response.statusCode,
    headers: response.headers,
    body: parsedBody,
  };
}

function upstreamHeaders(incomingHeaders, contentLength) {
  const headers = {
    accept: "application/json",
    "content-type": "application/json",
    "content-length": String(contentLength),
  };

  const configuredAuth = process.env.UPSTREAM_AUTHORIZATION;
  const configuredApiKey = process.env.UPSTREAM_API_KEY;
  const incomingAuth = incomingHeaders.authorization || incomingHeaders.Authorization;

  if (configuredAuth) {
    headers.authorization = configuredAuth;
  } else if (configuredApiKey) {
    headers.authorization = `Bearer ${configuredApiKey}`;
  } else if (incomingAuth) {
    headers.authorization = incomingAuth;
  }

  return headers;
}

function parseUpstreamBody(rawBody) {
  if (!rawBody) {
    return {};
  }

  try {
    return JSON.parse(rawBody);
  } catch (error) {
    return {
      error: {
        message: rawBody.slice(0, 2000),
        type: "upstream_non_json_response",
      },
    };
  }
}

function shouldRetryResponse(response) {
  if ([408, 409, 425, 429, 500, 502, 503, 504].includes(response.statusCode)) {
    return true;
  }

  const text = JSON.stringify(response.body || "").toLowerCase();
  return (
    text.includes("model overloaded") ||
    text.includes("no permits available") ||
    text.includes("overloaded") ||
    text.includes("too many requests") ||
    text.includes("temporarily unavailable")
  );
}

function shouldRetryError(error) {
  return [
    "ECONNRESET",
    "ECONNREFUSED",
    "EHOSTUNREACH",
    "ENETUNREACH",
    "ETIMEDOUT",
    "ESOCKETTIMEDOUT",
  ].includes(error.code) || /timeout/i.test(error.message);
}

function retryDelayMs(attempt, headers = {}) {
  const retryAfter = headers["retry-after"];
  if (retryAfter) {
    const retryAfterSeconds = Number(retryAfter);
    if (Number.isFinite(retryAfterSeconds)) {
      return Math.max(0, retryAfterSeconds * 1000);
    }
  }

  const exponential = RETRY_BASE_MS * 2 ** attempt;
  const capped = Math.min(exponential, 60000);
  const jitter = Math.floor(Math.random() * Math.min(1000, capped));
  return capped + jitter;
}

function mergeOpenAIEmbeddingResponses(batchResults, fallbackModel) {
  const data = [];
  const usage = {};
  let model = fallbackModel;
  let object = "list";

  for (const result of batchResults) {
    const body = result.body || {};
    if (!Array.isArray(body.data)) {
      throw httpError(502, body, "Upstream response does not include data array");
    }
    if (body.data.length !== result.inputCount) {
      throw httpError(502, body, "Upstream response data length does not match batch input length");
    }

    model = model || body.model;
    object = body.object || object;
    mergeUsage(usage, body.usage);

    body.data.forEach((item, responseOrder) => {
      const localIndex =
        Number.isInteger(item.index) && item.index >= 0 && item.index < result.inputCount
          ? item.index
          : responseOrder;
      data.push({ ...item, index: result.start + localIndex });
    });
  }

  data.sort((a, b) => a.index - b.index);

  const merged = {
    object,
    data,
    model,
  };

  if (Object.keys(usage).length > 0) {
    merged.usage = usage;
  }

  return merged;
}

function mergeUsage(target, source) {
  if (!source || typeof source !== "object") {
    return;
  }

  for (const [key, value] of Object.entries(source)) {
    if (typeof value === "number") {
      target[key] = (target[key] || 0) + value;
    }
  }
}

function requestBuffer(targetUrl, method, headers, bodyBuffer, timeoutMs) {
  const proxyUrl = proxyFor(targetUrl);

  if (proxyUrl && targetUrl.protocol === "https:") {
    return requestHttpsViaProxy(targetUrl, proxyUrl, method, headers, bodyBuffer, timeoutMs);
  }

  if (proxyUrl && targetUrl.protocol === "http:") {
    const proxyHeaders = { ...headers, host: targetUrl.host };
    addProxyAuthorization(proxyHeaders, proxyUrl);
    return sendRequest(
      proxyUrl.protocol === "https:" ? https : http,
      {
        hostname: proxyUrl.hostname,
        port: proxyUrl.port || (proxyUrl.protocol === "https:" ? 443 : 80),
        method,
        path: targetUrl.href,
        headers: proxyHeaders,
      },
      bodyBuffer,
      timeoutMs,
    );
  }

  return sendRequest(
    targetUrl.protocol === "https:" ? https : http,
    {
      hostname: targetUrl.hostname,
      port: targetUrl.port || (targetUrl.protocol === "https:" ? 443 : 80),
      method,
      path: `${targetUrl.pathname}${targetUrl.search}`,
      headers,
    },
    bodyBuffer,
    timeoutMs,
  );
}

function requestHttpsViaProxy(targetUrl, proxyUrl, method, headers, bodyBuffer, timeoutMs) {
  return new Promise((resolve, reject) => {
    const targetPort = targetUrl.port || 443;
    const connectHeaders = {
      host: `${targetUrl.hostname}:${targetPort}`,
    };
    addProxyAuthorization(connectHeaders, proxyUrl);

    const connectReq = (proxyUrl.protocol === "https:" ? https : http).request({
      hostname: proxyUrl.hostname,
      port: proxyUrl.port || (proxyUrl.protocol === "https:" ? 443 : 80),
      method: "CONNECT",
      path: `${targetUrl.hostname}:${targetPort}`,
      headers: connectHeaders,
      timeout: timeoutMs,
    });

    connectReq.once("connect", (connectRes, socket) => {
      if (connectRes.statusCode !== 200) {
        socket.destroy();
        reject(new Error(`Proxy CONNECT failed with ${connectRes.statusCode}`));
        return;
      }

      const tlsSocket = tls.connect({
        socket,
        servername: targetUrl.hostname,
      });

      tlsSocket.once("secureConnect", () => {
        sendRequest(
          https,
          {
            hostname: targetUrl.hostname,
            port: targetPort,
            method,
            path: `${targetUrl.pathname}${targetUrl.search}`,
            headers,
            createConnection: () => tlsSocket,
          },
          bodyBuffer,
          timeoutMs,
        ).then(resolve, reject);
      });

      tlsSocket.once("error", reject);
    });

    connectReq.once("timeout", () => {
      connectReq.destroy(new Error(`Proxy CONNECT timed out after ${timeoutMs}ms`));
    });
    connectReq.once("error", reject);
    connectReq.end();
  });
}

function sendRequest(transport, options, bodyBuffer, timeoutMs) {
  return new Promise((resolve, reject) => {
    const req = transport.request(options, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => {
        resolve({
          statusCode: res.statusCode || 0,
          headers: res.headers,
          body: Buffer.concat(chunks).toString("utf8"),
        });
      });
    });

    req.setTimeout(timeoutMs, () => {
      req.destroy(new Error(`Upstream request timed out after ${timeoutMs}ms`));
    });
    req.once("error", reject);
    req.end(bodyBuffer);
  });
}

function proxyFor(targetUrl) {
  if (isNoProxyHost(targetUrl.hostname, targetUrl.port)) {
    return null;
  }

  const rawProxy =
    targetUrl.protocol === "https:"
      ? process.env.HTTPS_PROXY || process.env.https_proxy || process.env.HTTP_PROXY || process.env.http_proxy
      : process.env.HTTP_PROXY || process.env.http_proxy;

  if (!rawProxy) {
    return null;
  }

  return new URL(rawProxy.includes("://") ? rawProxy : `http://${rawProxy}`);
}

function isNoProxyHost(hostname, port) {
  const noProxy = process.env.NO_PROXY || process.env.no_proxy || "";
  if (!noProxy) {
    return false;
  }

  const host = hostname.toLowerCase();
  const hostWithPort = port ? `${host}:${port}` : host;

  return noProxy
    .split(",")
    .map((entry) => entry.trim().toLowerCase())
    .filter(Boolean)
    .some((entry) => {
      if (entry === "*") {
        return true;
      }
      if (entry === host || entry === hostWithPort) {
        return true;
      }
      if (entry.startsWith(".")) {
        return host.endsWith(entry);
      }
      return host.endsWith(`.${entry}`);
    });
}

function addProxyAuthorization(headers, proxyUrl) {
  if (proxyUrl.username || proxyUrl.password) {
    const credentials = `${decodeURIComponent(proxyUrl.username)}:${decodeURIComponent(proxyUrl.password)}`;
    headers["proxy-authorization"] = `Basic ${Buffer.from(credentials).toString("base64")}`;
  }
}

function sendJson(res, statusCode, body) {
  const responseBody = JSON.stringify(body);
  res.writeHead(statusCode, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(responseBody),
  });
  res.end(responseBody);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function intEnv(name, defaultValue) {
  const value = process.env[name];
  if (value === undefined || value === "") {
    return defaultValue;
  }
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return parsed;
}

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}

function httpError(statusCode, upstreamBody, publicMessage) {
  const error = new Error(publicMessage);
  error.statusCode = statusCode;
  error.publicMessage = publicMessage;
  error.type = "embedding_proxy_error";
  error.upstreamBody = upstreamBody;
  return error;
}

function redactUrl(url) {
  const copy = new URL(url.href);
  copy.username = "";
  copy.password = "";
  return copy.toString();
}

function logRequest(inputCount, batchCount, startedAt, statusCode) {
  console.log(
    `[tei-batch-proxy] status=${statusCode} inputs=${inputCount} batches=${batchCount} duration_ms=${Date.now() - startedAt}`,
  );
}
