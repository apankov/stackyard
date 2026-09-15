import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Переменные окружения (Node.js 24 автоматически загрузит их через --env-file)
const STORAGE = (process.env.STORAGE_PATH || path.join(__dirname, '..', 'storage')).replace(/\/+$/, '');
const AUTH_TOKEN = process.env.AUTH_TOKEN || null;
const BUCKET_NAME = process.env.BUCKET_NAME || 'fathom';
const MAX_BODY_SIZE = 10 * 1024 * 1024; // Лимит 10 МБ для защиты диска и памяти

function safePathSegment(s) {
  if (!s || s === '.' || s === '..') {
    throw new Error('Invalid path segment');
  }
  return s.replace(/[^A-Za-z0-9._@-]/g, '_');
}

function sendTextResponse(res, code, text) {
  res.writeHead(code, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end(text);
}

// Безопасное сравнение строк для защиты от атак по времени (Timing Attacks)
function safeCompare(a, b) {
  if (!a || !b || a.length !== b.length) return false;
  return crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

const server = http.createServer(async (req, res) => {
  // Защита от медленных запросов (Slowloris DDOS)
  req.setTimeout(30000, () => {
    req.destroy();
  });

  try {
    // 1. Проверка токена
    if (AUTH_TOKEN) {
      const clientToken = req.headers['x-auth-token'];
      if (!clientToken || !safeCompare(clientToken.trim(), AUTH_TOKEN.trim())) {
        return sendTextResponse(res, 401, 'Unauthorized');
      }
    }

    // 2. Формирование путей (защищено от Path Traversal)
    const now = new Date();
    const timestamp = now.toISOString().replace(/[:T-]/g, '').slice(0, 14);
    const uniqueId = crypto.randomBytes(4).toString('hex');

    const bucket = safePathSegment(BUCKET_NAME);
    const key = `${timestamp}-${uniqueId}.json`;

    const bucketDir = path.join(STORAGE, bucket);
    const dataPath = path.join(bucketDir, key);
    const metaPath = path.join(bucketDir, `.${key.replace(/\//g, '__')}.meta.json`);

    const resolvedStorage = fs.realpathSync(STORAGE);
    fs.mkdirSync(bucketDir, { recursive: true });
    const resolvedBucketDir = fs.realpathSync(bucketDir);

    if (!resolvedBucketDir.startsWith(resolvedStorage)) {
      throw new Error('Path traversal attempt');
    }

    // 3. Чтение тела запроса с лимитом размера
    let bodyBuffers = [];
    let currentSize = 0;

    for await (const chunk of req) {
      currentSize += chunk.length;
      if (currentSize > MAX_BODY_SIZE) {
        return sendTextResponse(res, 413, 'Payload Too Large');
      }
      bodyBuffers.push(chunk);
    }

    let body = Buffer.concat(bodyBuffers);
    if (body.length === 0) {
      body = Buffer.from("Error: Empty payload received.");
    }

    // 4. Запись файлов на диск
    fs.writeFileSync(dataPath, body);

    const etag = `"${crypto.createHash('md5').update(body).digest('hex')}"`;
    const meta = {
      METHOD: req.method,
      Bucket: bucket,
      Key: key,
      ETag: etag,
      Size: body.length,
      LastModified: new Date().toISOString(),
    };

    fs.writeFileSync(metaPath, JSON.stringify(meta, null, 2));

    res.setHeader('ETag', etag);
    sendTextResponse(res, 200, 'OK');

  } catch (err) {
    console.error(err);
    sendTextResponse(res, 500, 'Internal Error');
  }
});

const PORT = process.env.PORT || 3000;
fs.mkdirSync(STORAGE, { recursive: true });

server.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
