/**
 * شرارة اون لاين — سيرفر واحد يتحكم بكل شي
 * ==========================================
 * ما يحتاج npm install — كله بمكتبات Node.js الأساسية.
 *
 * التشغيل:
 *   node server.js
 *
 * بعدها افتح:
 *   المتجر (عام):        http://SERVER_IP:3000/
 *   لوحة التحكم (مدير):  http://SERVER_IP:3000/admin
 *
 * أول مرة تفتح /admin بيطلب منك تحدد كلمة مرور المدير.
 * توكن تيليجرام ورقم الشات تضيفهم من داخل لوحة التحكم (تبويب الإعدادات) — مو من هذا الملف.
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = process.env.PORT || 3000;
const ROOT = __dirname;
const DATA_FILE = path.join(ROOT, 'data.json');
const UPLOADS_DIR = path.join(ROOT, 'uploads');
const PUBLIC_DIR = path.join(ROOT, 'public');

if (!fs.existsSync(UPLOADS_DIR)) fs.mkdirSync(UPLOADS_DIR, { recursive: true });

/* ========================= تخزين البيانات (ملف JSON بسيط) ========================= */
function defaultData() {
  return {
    products: [],
    orders: [],
    settings: {
      siteName: 'شرارة اون لاين',
      paymentMethods: [],
      adminPasswordHash: null // "salt:hash"
    }
  };
}

function readData() {
  try {
    const raw = fs.readFileSync(DATA_FILE, 'utf8');
    const parsed = JSON.parse(raw);
    // دمج مع القيم الافتراضية لو ناقص أي حقل
    const def = defaultData();
    return {
      products: parsed.products || def.products,
      orders: parsed.orders || def.orders,
      settings: Object.assign({}, def.settings, parsed.settings || {})
    };
  } catch (e) {
    return defaultData();
  }
}

function writeData(data) {
  fs.writeFileSync(DATA_FILE, JSON.stringify(data, null, 2), 'utf8');
}

if (!fs.existsSync(DATA_FILE)) writeData(defaultData());

/* ========================= كلمات المرور والجلسات ========================= */
function hashPassword(password) {
  const salt = crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(password, salt, 64).toString('hex');
  return `${salt}:${hash}`;
}
function verifyPassword(password, stored) {
  if (!stored) return false;
  const [salt, hash] = stored.split(':');
  if (!salt || !hash) return false;
  const check = crypto.scryptSync(password, salt, 64).toString('hex');
  const a = Buffer.from(hash, 'hex');
  const b = Buffer.from(check, 'hex');
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

const sessions = new Map(); // token -> expiresAt
const SESSION_TTL_MS = 12 * 60 * 60 * 1000; // 12 ساعة

function createSession() {
  const token = crypto.randomBytes(32).toString('hex');
  sessions.set(token, Date.now() + SESSION_TTL_MS);
  return token;
}
function isValidSession(token) {
  if (!token) return false;
  const exp = sessions.get(token);
  if (!exp) return false;
  if (Date.now() > exp) { sessions.delete(token); return false; }
  return true;
}
function parseCookies(req) {
  const header = req.headers.cookie || '';
  const out = {};
  header.split(';').forEach(part => {
    const idx = part.indexOf('=');
    if (idx === -1) return;
    const k = part.slice(0, idx).trim();
    const v = part.slice(idx + 1).trim();
    if (k) out[k] = decodeURIComponent(v);
  });
  return out;
}
function requireAdmin(req) {
  const cookies = parseCookies(req);
  return isValidSession(cookies.session);
}

/* ========================= أدوات مساعدة عامة ========================= */
function sendJSON(res, code, obj, extraHeaders) {
  const body = JSON.stringify(obj);
  res.writeHead(code, Object.assign({
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body)
  }, extraHeaders || {}));
  res.end(body);
}

function readBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', chunk => {
      size += chunk.length;
      if (size > maxBytes) { req.destroy(); reject(new Error('too_large')); return; }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

async function readJSON(req, maxBytes) {
  const buf = await readBody(req, maxBytes || 200000);
  if (!buf.length) return {};
  try { return JSON.parse(buf.toString('utf8')); }
  catch (e) { throw new Error('bad_json'); }
}

// حماية بسيطة من كثرة الطلبات (على مستوى endpoint معين لكل IP)
const rateBuckets = new Map();
function rateLimited(key, minGapMs) {
  const now = Date.now();
  const last = rateBuckets.get(key) || 0;
  if (now - last < minGapMs) return true;
  rateBuckets.set(key, now);
  return false;
}
function clientIp(req) {
  return req.socket.remoteAddress || 'unknown';
}

function escapeText(s) {
  return String(s == null ? '' : s).slice(0, 3000);
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon'
};

function serveStaticFile(res, filePath) {
  fs.readFile(filePath, (err, content) => {
    if (err) { sendJSON(res, 404, { ok: false, error: 'not_found' }); return; }
    const ext = path.extname(filePath).toLowerCase();
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
    res.end(content);
  });
}

/* ========================= السيرفر ========================= */
const server = http.createServer(async (req, res) => {
  const parsed = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const pathname = decodeURIComponent(parsed.pathname);
  const method = req.method;

  // CORS بسيط (يسمح لو حبيت تفتح الملفات من دومين ثاني لاحقاً)
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  if (method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  try {
    /* -------- صفحات ثابتة -------- */
    if (method === 'GET' && (pathname === '/' || pathname === '/store' || pathname === '/store.html')) {
      return serveStaticFile(res, path.join(PUBLIC_DIR, 'store.html'));
    }
    if (method === 'GET' && (pathname === '/admin' || pathname === '/admin.html')) {
      return serveStaticFile(res, path.join(PUBLIC_DIR, 'admin.html'));
    }
    if (method === 'GET' && pathname.startsWith('/uploads/')) {
      const safe = path.normalize(pathname).replace(/^(\.\.[/\\])+/, '');
      const filePath = path.join(ROOT, safe);
      if (!filePath.startsWith(UPLOADS_DIR)) { sendJSON(res, 403, { ok: false }); return; }
      return serveStaticFile(res, filePath);
    }

    /* -------- عام: معلومات المتجر -------- */
    if (method === 'GET' && pathname === '/api/store-info') {
      const data = readData();
      return sendJSON(res, 200, {
        ok: true,
        siteName: data.settings.siteName,
        paymentMethods: (data.settings.paymentMethods || []).map(p => ({ id: p.id, label: p.label, details: p.details }))
      });
    }

    /* -------- عام: المنتجات -------- */
    if (method === 'GET' && pathname === '/api/products') {
      const data = readData();
      return sendJSON(res, 200, { ok: true, products: data.products });
    }

    /* -------- عام: إنشاء طلب -------- */
    if (method === 'POST' && pathname === '/api/orders') {
      if (rateLimited('order:' + clientIp(req), 2000)) {
        return sendJSON(res, 429, { ok: false, error: 'too_many_requests' });
      }
      const body = await readJSON(req, 20000);
      const customerName = escapeText(body.customerName).trim();
      const phone = escapeText(body.phone).trim();
      const address = escapeText(body.address).trim();
      const notes = escapeText(body.notes).trim();
      const paymentMethodId = body.paymentMethodId || null;
      const cartItems = Array.isArray(body.items) ? body.items : [];

      if (!customerName || !phone || !address || cartItems.length === 0) {
        return sendJSON(res, 400, { ok: false, error: 'missing_fields' });
      }
      if (customerName.length > 60 || phone.length > 20 || address.length > 250 || notes.length > 250) {
        return sendJSON(res, 400, { ok: false, error: 'field_too_long' });
      }

      const data = readData();

      // السيرفر يحسب الأسعار بنفسه، ما يثق بالسعر المرسل من المتصفح
      const items = [];
      let total = 0;
      for (const ci of cartItems) {
        const p = data.products.find(pr => pr.id === ci.productId);
        if (!p || p.inStock === false) continue;
        const qty = Math.max(1, Math.min(50, parseInt(ci.qty) || 1));
        items.push({ productId: p.id, name: p.name, price: p.price, qty });
        total += p.price * qty;
      }
      if (items.length === 0) return sendJSON(res, 400, { ok: false, error: 'no_valid_items' });

      const pm = (data.settings.paymentMethods || []).find(p => p.id === paymentMethodId);
      if ((data.settings.paymentMethods || []).length > 0 && !pm) {
        return sendJSON(res, 400, { ok: false, error: 'invalid_payment_method' });
      }

      const order = {
        id: crypto.randomBytes(8).toString('hex'),
        customerName, phone, address, notes,
        items, total,
        paymentMethodLabel: pm ? pm.label : 'غير محدد',
        status: 'pending',
        createdAt: Date.now()
      };
      data.orders.push(order);
      writeData(data);

      return sendJSON(res, 200, { ok: true, orderId: order.id });
    }

    /* -------- إعداد كلمة مرور المدير أول مرة -------- */
    if (method === 'POST' && pathname === '/api/admin/setup') {
      const data = readData();
      if (data.settings.adminPasswordHash) {
        return sendJSON(res, 409, { ok: false, error: 'already_setup' });
      }
      const body = await readJSON(req, 2000);
      const password = String(body.password || '');
      if (password.length < 4) return sendJSON(res, 400, { ok: false, error: 'weak_password' });
      data.settings.adminPasswordHash = hashPassword(password);
      writeData(data);
      const token = createSession();
      return sendJSON(res, 200, { ok: true }, {
        'Set-Cookie': `session=${token}; HttpOnly; Path=/; Max-Age=${SESSION_TTL_MS / 1000}; SameSite=Lax`
      });
    }

    /* -------- تسجيل دخول المدير -------- */
    if (method === 'POST' && pathname === '/api/admin/login') {
      if (rateLimited('login:' + clientIp(req), 1500)) {
        return sendJSON(res, 429, { ok: false, error: 'too_many_requests' });
      }
      const data = readData();
      const body = await readJSON(req, 2000);
      const password = String(body.password || '');
      if (!verifyPassword(password, data.settings.adminPasswordHash)) {
        return sendJSON(res, 401, { ok: false, error: 'wrong_password' });
      }
      const token = createSession();
      return sendJSON(res, 200, { ok: true }, {
        'Set-Cookie': `session=${token}; HttpOnly; Path=/; Max-Age=${SESSION_TTL_MS / 1000}; SameSite=Lax`
      });
    }

    if (method === 'POST' && pathname === '/api/admin/logout') {
      const cookies = parseCookies(req);
      if (cookies.session) sessions.delete(cookies.session);
      return sendJSON(res, 200, { ok: true }, {
        'Set-Cookie': `session=; HttpOnly; Path=/; Max-Age=0; SameSite=Lax`
      });
    }

    if (method === 'GET' && pathname === '/api/admin/session') {
      const data = readData();
      return sendJSON(res, 200, {
        ok: true,
        hasAdmin: !!data.settings.adminPasswordHash,
        loggedIn: requireAdmin(req)
      });
    }

    /* -------- كل ما تحت هذا السطر يتطلب تسجيل دخول مدير -------- */
    if (pathname.startsWith('/api/admin/') && pathname !== '/api/admin/setup' && pathname !== '/api/admin/login' && pathname !== '/api/admin/logout' && pathname !== '/api/admin/session') {
      if (!requireAdmin(req)) {
        return sendJSON(res, 401, { ok: false, error: 'unauthorized' });
      }
    }

    if (method === 'GET' && pathname === '/api/admin/orders') {
      const data = readData();
      return sendJSON(res, 200, { ok: true, orders: data.orders });
    }

    if (method === 'PATCH' && pathname.match(/^\/api\/admin\/orders\/[a-f0-9]+$/)) {
      const id = pathname.split('/').pop();
      const body = await readJSON(req, 2000);
      const allowed = ['pending', 'approved', 'rejected', 'done'];
      if (!allowed.includes(body.status)) return sendJSON(res, 400, { ok: false, error: 'invalid_status' });
      const data = readData();
      const order = data.orders.find(o => o.id === id);
      if (!order) return sendJSON(res, 404, { ok: false, error: 'not_found' });
      order.status = body.status;
      writeData(data);
      return sendJSON(res, 200, { ok: true });
    }

    if (method === 'POST' && pathname === '/api/admin/products') {
      const body = await readJSON(req, 3000000); // يسمح بحجم صورة معقول لو أُرسلت مباشرة
      const data = readData();
      const product = {
        id: crypto.randomBytes(8).toString('hex'),
        name: escapeText(body.name).slice(0, 80).trim(),
        price: Math.max(0, Number(body.price) || 0),
        category: escapeText(body.category).slice(0, 40).trim(),
        description: escapeText(body.description).slice(0, 300).trim(),
        image: typeof body.image === 'string' ? body.image.slice(0, 500) : '',
        inStock: body.inStock !== false
      };
      if (!product.name) return sendJSON(res, 400, { ok: false, error: 'missing_name' });
      data.products.push(product);
      writeData(data);
      return sendJSON(res, 200, { ok: true, product });
    }

    if (method === 'PUT' && pathname.match(/^\/api\/admin\/products\/[a-f0-9]+$/)) {
      const id = pathname.split('/').pop();
      const body = await readJSON(req, 3000000);
      const data = readData();
      const product = data.products.find(p => p.id === id);
      if (!product) return sendJSON(res, 404, { ok: false, error: 'not_found' });
      if (typeof body.name === 'string') product.name = escapeText(body.name).slice(0, 80).trim();
      if (body.price !== undefined) product.price = Math.max(0, Number(body.price) || 0);
      if (typeof body.category === 'string') product.category = escapeText(body.category).slice(0, 40).trim();
      if (typeof body.description === 'string') product.description = escapeText(body.description).slice(0, 300).trim();
      if (typeof body.image === 'string') product.image = body.image.slice(0, 500);
      if (body.inStock !== undefined) product.inStock = !!body.inStock;
      writeData(data);
      return sendJSON(res, 200, { ok: true, product });
    }

    if (method === 'DELETE' && pathname.match(/^\/api\/admin\/products\/[a-f0-9]+$/)) {
      const id = pathname.split('/').pop();
      const data = readData();
      data.products = data.products.filter(p => p.id !== id);
      writeData(data);
      return sendJSON(res, 200, { ok: true });
    }

    if (method === 'POST' && pathname === '/api/admin/upload-image') {
      const body = await readJSON(req, 8000000); // حتى ~8MB base64
      const b64 = String(body.imageBase64 || '');
      const match = b64.match(/^data:image\/(png|jpeg|jpg|webp);base64,(.+)$/);
      if (!match) return sendJSON(res, 400, { ok: false, error: 'invalid_image' });
      const ext = match[1] === 'jpeg' ? 'jpg' : match[1];
      const buf = Buffer.from(match[2], 'base64');
      if (buf.length > 6 * 1024 * 1024) return sendJSON(res, 400, { ok: false, error: 'image_too_large' });
      const filename = crypto.randomBytes(10).toString('hex') + '.' + ext;
      fs.writeFileSync(path.join(UPLOADS_DIR, filename), buf);
      return sendJSON(res, 200, { ok: true, url: '/uploads/' + filename });
    }

    if (method === 'GET' && pathname === '/api/admin/settings') {
      const data = readData();
      return sendJSON(res, 200, {
        ok: true,
        siteName: data.settings.siteName,
        paymentMethods: data.settings.paymentMethods || []
      });
    }

    if (method === 'POST' && pathname === '/api/admin/settings') {
      const body = await readJSON(req, 200000);
      const data = readData();
      if (typeof body.siteName === 'string' && body.siteName.trim()) {
        data.settings.siteName = body.siteName.trim().slice(0, 60);
      }
      if (Array.isArray(body.paymentMethods)) {
        data.settings.paymentMethods = body.paymentMethods.map(pm => ({
          id: pm.id || crypto.randomBytes(6).toString('hex'),
          label: escapeText(pm.label).slice(0, 60).trim(),
          details: escapeText(pm.details).slice(0, 300).trim()
        })).filter(pm => pm.label);
      }
      writeData(data);
      return sendJSON(res, 200, { ok: true });
    }

    if (method === 'POST' && pathname === '/api/admin/change-password') {
      const body = await readJSON(req, 2000);
      const newPassword = String(body.newPassword || '');
      if (newPassword.length < 4) return sendJSON(res, 400, { ok: false, error: 'weak_password' });
      const data = readData();
      data.settings.adminPasswordHash = hashPassword(newPassword);
      writeData(data);
      return sendJSON(res, 200, { ok: true });
    }

    // لا شيء طابق
    return sendJSON(res, 404, { ok: false, error: 'not_found' });

  } catch (err) {
    if (err && err.message === 'too_large') return sendJSON(res, 413, { ok: false, error: 'payload_too_large' });
    if (err && err.message === 'bad_json') return sendJSON(res, 400, { ok: false, error: 'bad_json' });
    return sendJSON(res, 500, { ok: false, error: 'server_error' });
  }
});

server.listen(PORT, () => {
  console.log(`شرارة اون لاين شغالة على المنفذ ${PORT}`);
  console.log(`المتجر:        http://localhost:${PORT}/`);
  console.log(`لوحة التحكم:   http://localhost:${PORT}/admin`);
});
