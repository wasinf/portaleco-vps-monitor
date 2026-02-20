const express = require("express");
const cors = require("cors");
const os = require("os");
const { exec } = require("child_process");
const http = require("http");
const fs = require("fs");
const crypto = require("crypto");
const { MIN_PASSWORD_LENGTH, openAuthStore } = require("./auth-store");

const app = express();
const PORT = process.env.PORT || 4000;
const AUTH_ENABLED = String(process.env.AUTH_ENABLED || "true").toLowerCase() !== "false";
const AUTH_USERNAME = process.env.AUTH_USERNAME || "admin";
const AUTH_PASSWORD = process.env.AUTH_PASSWORD || "change-me";
const AUTH_TOKEN_SECRET = process.env.AUTH_TOKEN_SECRET || "change-this-token-secret";
const AUTH_TOKEN_TTL_SECONDS = Number(process.env.AUTH_TOKEN_TTL_SECONDS || 60 * 60 * 12);
const AUTH_DB_PATH = process.env.AUTH_DB_PATH || "/data/auth.db";
const LOG_LEVEL = process.env.LOG_LEVEL || "info";
const ALLOWED_ORIGINS = String(process.env.ALLOWED_ORIGINS || "")
  .split(",")
  .map((value) => value.trim())
  .filter(Boolean);
const AUTH_FAIL_ON_INSECURE_DEFAULTS = String(process.env.AUTH_FAIL_ON_INSECURE_DEFAULTS || "false").toLowerCase() === "true";
const authStore = openAuthStore(AUTH_DB_PATH);

const newRequestId = () => {
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  return crypto.randomBytes(16).toString("hex");
};

const toLatencyMs = (startNs) => {
  const elapsed = process.hrtime.bigint() - startNs;
  return Number(elapsed) / 1e6;
};

const clientIp = (req) => {
  const fwd = req.headers["x-forwarded-for"];
  if (typeof fwd === "string" && fwd.trim()) {
    return fwd.split(",")[0].trim();
  }
  return req.socket?.remoteAddress || req.ip || "";
};

const logJson = (level, payload) => {
  const record = {
    ts: new Date().toISOString(),
    level,
    service: "portaleco-vps-monitor-backend",
    ...payload
  };
  console.log(JSON.stringify(record));
};

const corsOptions = {
  origin: (origin, callback) => {
    // Requests sem Origin (curl, healthchecks internos) continuam permitidos.
    if (!origin) return callback(null, true);
    if (ALLOWED_ORIGINS.length === 0) return callback(null, false);
    return callback(null, ALLOWED_ORIGINS.includes(origin));
  },
  credentials: false
};

app.use(cors(corsOptions));
app.use(express.json());
app.use((req, res, next) => {
  const startNs = process.hrtime.bigint();
  const requestId = newRequestId();
  req.requestId = requestId;
  res.setHeader("x-request-id", requestId);

  res.on("finish", () => {
    if (LOG_LEVEL === "silent") return;
    logJson("info", {
      event: "http_request",
      request_id: requestId,
      method: req.method,
      path: req.originalUrl || req.url,
      status: res.statusCode,
      latency_ms: Number(toLatencyMs(startNs).toFixed(2)),
      ip: clientIp(req),
      user: req.auth?.sub || null,
      role: req.auth?.role || null
    });
  });

  next();
});
app.use(express.static("/workspace/frontend"));

const base64UrlEncode = (value) =>
  Buffer.from(value)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");

const base64UrlDecode = (value) => {
  const input = String(value || "").replace(/-/g, "+").replace(/_/g, "/");
  const padLength = (4 - (input.length % 4)) % 4;
  const padded = input + "=".repeat(padLength);
  return Buffer.from(padded, "base64").toString("utf8");
};

const signAuthToken = (user) => {
  const header = { alg: "HS256", typ: "JWT" };
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    sub: user.username,
    role: user.role || "viewer",
    iat: now,
    exp: now + Math.max(60, Number(AUTH_TOKEN_TTL_SECONDS) || 0)
  };
  const h = base64UrlEncode(JSON.stringify(header));
  const p = base64UrlEncode(JSON.stringify(payload));
  const sig = crypto
    .createHmac("sha256", AUTH_TOKEN_SECRET)
    .update(`${h}.${p}`)
    .digest("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
  return `${h}.${p}.${sig}`;
};

const verifyAuthToken = (token) => {
  const parts = String(token || "").split(".");
  if (parts.length !== 3) {
    throw new Error("formato de token invalido");
  }

  const [h, p, sig] = parts;
  const expected = crypto
    .createHmac("sha256", AUTH_TOKEN_SECRET)
    .update(`${h}.${p}`)
    .digest("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");

  if (sig.length !== expected.length) {
    throw new Error("assinatura de token invalida");
  }
  if (!crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expected))) {
    throw new Error("assinatura de token invalida");
  }

  const payload = JSON.parse(base64UrlDecode(p));
  const now = Math.floor(Date.now() / 1000);
  if (!payload.exp || now >= payload.exp) {
    throw new Error("token expirado");
  }

  return payload;
};

const getBearerToken = (req) => {
  const auth = req.headers.authorization || "";
  const match = auth.match(/^Bearer\s+(.+)$/i);
  return match ? match[1] : "";
};

const apiAuthMiddleware = (req, res, next) => {
  if (!AUTH_ENABLED) return next();
  if (req.path === "/auth/login") return next();

  const token = getBearerToken(req);
  if (!token) {
    return res.status(401).json({
      status: "error",
      error: "nao autorizado",
      detail: "token ausente"
    });
  }

  try {
    const payload = verifyAuthToken(token);
    req.auth = payload;
    return next();
  } catch (err) {
    return res.status(401).json({
      status: "error",
      error: "nao autorizado",
      detail: String(err.message || err)
    });
  }
};

const requireAdmin = (req, res, next) => {
  if (req.auth?.role === "admin") return next();
  return res.status(403).json({
    status: "error",
    error: "acesso negado",
    detail: "apenas admin pode executar esta operacao"
  });
};

const dockerApi = (path) =>
  new Promise((resolve, reject) => {
    const socketPath = "/var/run/docker.sock";
    if (!fs.existsSync(socketPath)) {
      return reject(new Error("docker socket nao encontrado"));
    }

    const req = http.request(
      { socketPath, path, method: "GET" },
      (res) => {
        let data = "";
        res.on("data", (chunk) => {
          data += chunk;
        });
        res.on("end", () => {
          if (res.statusCode >= 400) {
            return reject(
              new Error(`docker api status ${res.statusCode}: ${data}`)
            );
          }
          try {
            resolve(JSON.parse(data || "null"));
          } catch (e) {
            reject(e);
          }
        });
      }
    );

    req.on("error", reject);
    req.end();
  });

const isDockerNotFoundError = (err) => {
  const msg = String(err && err.message ? err.message : err || "").toLowerCase();
  return msg.includes("docker api status 404") || msg.includes("no such container") || msg.includes("no such object");
};

const dockerContainerExists = async (id) => {
  const containerId = String(id || "").trim();
  if (!containerId) return false;
  try {
    await dockerApi(`/containers/${containerId}/json`);
    return true;
  } catch (err) {
    if (isDockerNotFoundError(err)) return false;
    throw err;
  }
};

const isMonitorOrphanContainer = (container) => {
  const rawName = Array.isArray(container?.Names) && container.Names[0]
    ? String(container.Names[0]).replace(/^\//, "")
  : "";
  const state = String(container?.State || "").toLowerCase();
  const isStopped = state !== "running";
  return isStopped && /^[a-f0-9]{12}_portaleco-vps-monitor-(backend|frontend)$/i.test(rawName);
};

const getContainerName = (container) =>
  Array.isArray(container?.Names) && container.Names[0]
    ? String(container.Names[0]).replace(/^\//, "")
    : "";

const deriveAutoAppName = (container) => {
  const labels = container?.Labels || {};
  const name = getContainerName(container);
  const composeProject = String(labels["com.docker.compose.project"] || "").trim();
  if (composeProject) return composeProject;

  if (name.startsWith("cloudflared")) return "cloudflared";
  if (name.startsWith("nc-empresa")) return "nc-empresa";
  if (name.startsWith("nc-familia")) return "nc-familia";
  return name || "desconhecido";
};

const cpuSnapshot = () => {
  const cpus = os.cpus();
  let idle = 0;
  let total = 0;
  cpus.forEach((cpu) => {
    idle += cpu.times.idle;
    total +=
      cpu.times.user +
      cpu.times.nice +
      cpu.times.sys +
      cpu.times.irq +
      cpu.times.idle;
  });
  return { idle, total };
};

const getCpuPercent = () =>
  new Promise((resolve) => {
    const s1 = cpuSnapshot();
    setTimeout(() => {
      const s2 = cpuSnapshot();
      const idle = s2.idle - s1.idle;
      const total = s2.total - s1.total;
      if (total <= 0) return resolve(0);
      const usage = (1 - idle / total) * 100;
      resolve(Number(usage.toFixed(2)));
    }, 200);
  });

const getDiskUsage = () =>
  new Promise((resolve) => {
    exec("df -B1 --output=target,size,used,pcent -x tmpfs -x devtmpfs -x overlay -x squashfs -x nsfs", (err, stdout) => {
      if (err || !stdout) {
        return resolve({ total: 0, used: 0, percent: 0, volumes: [] });
      }
      const lines = String(stdout || "")
        .split("\n")
        .map((line) => line.trim())
        .filter(Boolean);

      const rows = lines.slice(1);
      const volumes = rows
        .map((line) => {
          const cols = line.split(/\s+/);
          const mount = String(cols[0] || "");
          const total = Number(cols[1] || 0);
          const used = Number(cols[2] || 0);
          const pctRaw = String(cols[3] || "").replace("%", "");
          const percent = Number(pctRaw || 0);
          return { mount, total, used, percent };
        })
        .filter((v) => v.mount && Number.isFinite(v.total) && v.total > 0)
        .sort((a, b) => a.mount.localeCompare(b.mount, "pt-BR"));

      const total = volumes.reduce((sum, v) => sum + Number(v.total || 0), 0);
      const used = volumes.reduce((sum, v) => sum + Number(v.used || 0), 0);
      const percent = total > 0 ? Number(((used / total) * 100).toFixed(2)) : 0;
      resolve({ total, used, percent, volumes });
    });
  });

const toHumanPorts = (ports) => {
  if (!Array.isArray(ports) || ports.length === 0) return "";
  return ports
    .map((p) => {
      const pub = p.PublicPort ? `${p.IP || "0.0.0.0"}:${p.PublicPort}->` : "";
      const priv = `${p.PrivatePort}/${p.Type || "tcp"}`;
      return `${pub}${priv}`;
    })
    .join(", ");
};

const sh = (cmd) =>
  new Promise((resolve, reject) => {
    exec(cmd, { maxBuffer: 1024 * 1024 * 10 }, (err, stdout) => {
      if (err) return reject(err);
      resolve(String(stdout || "").trim());
    });
  });

const trafficState = {
  containers: new Map(),
  totals: null
};

const extractBytesFromStats = (stats) => {
  const networks = stats && typeof stats === "object" ? stats.networks : null;
  if (networks && typeof networks === "object") {
    let rx = 0;
    let tx = 0;
    Object.values(networks).forEach((net) => {
      rx += Number(net?.rx_bytes || 0);
      tx += Number(net?.tx_bytes || 0);
    });
    return { rx, tx };
  }

  // compatibilidade com payload legado que possui apenas "network"
  return {
    rx: Number(stats?.network?.rx_bytes || 0),
    tx: Number(stats?.network?.tx_bytes || 0)
  };
};

const rateFromPrevious = (prev, current, nowMs) => {
  if (!prev || !Number(prev.ts_ms)) {
    return { rx_bps: 0, tx_bps: 0 };
  }
  const elapsedSeconds = (nowMs - Number(prev.ts_ms)) / 1000;
  if (elapsedSeconds <= 0) {
    return { rx_bps: 0, tx_bps: 0 };
  }

  const rxDiff = Math.max(0, Number(current.rx_bytes || 0) - Number(prev.rx_bytes || 0));
  const txDiff = Math.max(0, Number(current.tx_bytes || 0) - Number(prev.tx_bytes || 0));
  return {
    rx_bps: Number((rxDiff / elapsedSeconds).toFixed(2)),
    tx_bps: Number((txDiff / elapsedSeconds).toFixed(2))
  };
};

app.get("/health", (req, res) => {
  return res.json({ status: "ok", service: "infra-dashboard-backend" });
});

app.post("/api/auth/login", (req, res) => {
  const username = String(req.body?.username || "");
  const password = String(req.body?.password || "");

  if (!AUTH_ENABLED) {
    return res.json({
      status: "ok",
      auth_enabled: false
    });
  }

  if (!username || !password) {
    return res.status(400).json({
      status: "error",
      error: "credenciais invalidas",
      detail: "usuario e senha sao obrigatorios"
    });
  }

  const user = authStore.validateCredentials(username, password);
  if (!user) {
    return res.status(401).json({
      status: "error",
      error: "credenciais invalidas"
    });
  }

  const token = signAuthToken(user);
  return res.json({
    status: "ok",
    token,
    token_type: "Bearer",
    expires_in: Math.max(60, Number(AUTH_TOKEN_TTL_SECONDS) || 0),
    user: { username: user.username, role: user.role }
  });
});

app.use("/api", apiAuthMiddleware);

app.get("/api/auth/me", (req, res) => {
  return res.json({
    status: "ok",
    auth_enabled: AUTH_ENABLED,
    user: { username: req.auth?.sub || AUTH_USERNAME, role: req.auth?.role || "viewer" }
  });
});

app.get("/api/auth/users", requireAdmin, (req, res) => {
  return res.json({
    status: "ok",
    users: authStore.listUsers()
  });
});

app.post("/api/auth/users", requireAdmin, (req, res) => {
  const username = String(req.body?.username || "").trim();
  const password = String(req.body?.password || "");
  const role = String(req.body?.role || "viewer");

  if (!username || !password) {
    return res.status(400).json({
      status: "error",
      error: "campos obrigatorios",
      detail: "username e password sao obrigatorios"
    });
  }

  try {
    const user = authStore.createUser(username, password, role);
    return res.status(201).json({
      status: "ok",
      user: {
        username: user.username,
        role: user.role,
        active: Boolean(user.active),
        created_at: user.created_at,
        updated_at: user.updated_at
      }
    });
  } catch (err) {
    return res.status(400).json({
      status: "error",
      error: "falha ao criar usuario",
      detail: String(err.message || err)
    });
  }
});

app.patch("/api/auth/users/:username/active", requireAdmin, (req, res) => {
  const targetUsername = String(req.params?.username || "").trim();
  const active = Boolean(req.body?.active);

  if (!targetUsername) {
    return res.status(400).json({
      status: "error",
      error: "username obrigatorio"
    });
  }

  try {
    const user = authStore.setUserActive(targetUsername, active);
    return res.json({
      status: "ok",
      user: {
        username: user.username,
        role: user.role,
        active: Boolean(user.active),
        created_at: user.created_at,
        updated_at: user.updated_at
      }
    });
  } catch (err) {
    return res.status(400).json({
      status: "error",
      error: "falha ao atualizar usuario",
      detail: String(err.message || err)
    });
  }
});

app.post("/api/auth/change-password", (req, res) => {
  const currentPassword = String(req.body?.current_password || "");
  const newPassword = String(req.body?.new_password || "");
  if (!currentPassword || !newPassword) {
    return res.status(400).json({
      status: "error",
      error: "campos obrigatorios",
      detail: "current_password e new_password sao obrigatorios"
    });
  }

  try {
    authStore.changePassword(req.auth?.sub || "", currentPassword, newPassword);
    return res.json({
      status: "ok",
      detail: "senha alterada com sucesso"
    });
  } catch (err) {
    return res.status(400).json({
      status: "error",
      error: "falha ao alterar senha",
      detail: String(err.message || err || `senha deve ter ao menos ${MIN_PASSWORD_LENGTH} caracteres`)
    });
  }
});

app.get("/api/system", async (req, res) => {
  const memTotal = os.totalmem();
  const memUsed = memTotal - os.freemem();
  const memPercent = memTotal > 0 ? Number(((memUsed / memTotal) * 100).toFixed(2)) : 0;

  const [cpuPercent, disk] = await Promise.all([getCpuPercent(), getDiskUsage()]);

  return res.json({
    status: "ok",
    hostname: process.env.HOST_HOSTNAME || os.hostname(),
    cpu_percent: cpuPercent,
    cpu_cores: os.cpus().length,
    memory: { total: memTotal, used: memUsed, percent: memPercent },
    disk,
    uptime_seconds: Math.floor(os.uptime())
  });
});

app.get("/api/docker", async (req, res) => {
  try {
    const containersRaw = await dockerApi("/containers/json?all=1");
    const list = Array.isArray(containersRaw) ? containersRaw : [];

    // Alguns hosts com Docker bugado retornam containers "fantasma" no /containers/json
    // que falham em /containers/{id}/json (404/no such object). Filtramos antes de exibir.
    const checks = await Promise.all(
      list.map(async (c) => ({
        container: c,
        exists: await dockerContainerExists(c?.Id)
      }))
    );

    const realContainers = checks
      .filter((entry) => entry.exists)
      .filter((entry) => !isMonitorOrphanContainer(entry.container))
      .map((entry) => entry.container);

    const items = realContainers.map((c) => ({
      name: (Array.isArray(c.Names) && c.Names[0] ? c.Names[0].replace(/^\//, "") : ""),
      image: c.Image || "",
      state: String(c.State || "").toLowerCase(),
      status: c.Status || "",
      running: c.State === "running",
      uptime: c.Status || "",
      ports: toHumanPorts(c.Ports),
      network: c.HostConfig && c.HostConfig.NetworkMode ? c.HostConfig.NetworkMode : ""
    }));

    return res.json({
      status: "ok",
      total: items.length,
      running: items.filter((i) => i.running).length,
      containers: items
    });
  } catch (err) {
    return res.status(500).json({
      status: "error",
      error: "Falha ao ler containers Docker",
      detail: String(err.message || err)
    });
  }
});

app.get("/api/traffic", async (req, res) => {
  try {
    const nowMs = Date.now();
    const containersRaw = await dockerApi("/containers/json?all=0");
    const runningContainers = Array.isArray(containersRaw) ? containersRaw : [];

    const containerTraffic = await Promise.all(
      runningContainers.map(async (c) => {
        const id = String(c.Id || "");
        const name = Array.isArray(c.Names) && c.Names[0] ? c.Names[0].replace(/^\//, "") : id.slice(0, 12);
        const stats = await dockerApi(`/containers/${id}/stats?stream=false`);
        const bytes = extractBytesFromStats(stats);
        const current = {
          rx_bytes: Number(bytes.rx || 0),
          tx_bytes: Number(bytes.tx || 0),
          ts_ms: nowMs
        };
        const prev = trafficState.containers.get(id);
        const rate = rateFromPrevious(prev, current, nowMs);
        trafficState.containers.set(id, current);
        return {
          id,
          name,
          rx_bytes: current.rx_bytes,
          tx_bytes: current.tx_bytes,
          rx_bps: rate.rx_bps,
          tx_bps: rate.tx_bps
        };
      })
    );

    const validIds = new Set(containerTraffic.map((c) => c.id));
    Array.from(trafficState.containers.keys()).forEach((id) => {
      if (!validIds.has(id)) trafficState.containers.delete(id);
    });

    const totalsCurrent = containerTraffic.reduce(
      (acc, item) => {
        acc.rx_bytes += Number(item.rx_bytes || 0);
        acc.tx_bytes += Number(item.tx_bytes || 0);
        return acc;
      },
      { rx_bytes: 0, tx_bytes: 0, ts_ms: nowMs }
    );
    const totalsRate = rateFromPrevious(trafficState.totals, totalsCurrent, nowMs);
    trafficState.totals = totalsCurrent;

    const byId = new Map(containerTraffic.map((c) => [c.id, c]));
    const grouped = new Map();
    runningContainers.forEach((container) => {
      const id = String(container?.Id || "");
      const traffic = byId.get(id);
      if (!traffic) return;
      const app = deriveAutoAppName(container);
      if (!grouped.has(app)) {
        grouped.set(app, {
          app,
          containers: [],
          rx_bytes: 0,
          tx_bytes: 0,
          rx_bps: 0,
          tx_bps: 0
        });
      }
      const item = grouped.get(app);
      item.containers.push(traffic.name);
      item.rx_bytes += Number(traffic.rx_bytes || 0);
      item.tx_bytes += Number(traffic.tx_bytes || 0);
      item.rx_bps += Number(traffic.rx_bps || 0);
      item.tx_bps += Number(traffic.tx_bps || 0);
    });

    const byApp = Array.from(grouped.values())
      .map((item) => ({
        ...item,
        rx_bps: Number(item.rx_bps.toFixed(2)),
        tx_bps: Number(item.tx_bps.toFixed(2))
      }))
      .sort((a, b) => (Number(b.rx_bps || 0) + Number(b.tx_bps || 0)) - (Number(a.rx_bps || 0) + Number(a.tx_bps || 0)));

    return res.json({
      status: "ok",
      generated_at: new Date(nowMs).toISOString(),
      total: {
        rx_bytes: totalsCurrent.rx_bytes,
        tx_bytes: totalsCurrent.tx_bytes,
        rx_bps: totalsRate.rx_bps,
        tx_bps: totalsRate.tx_bps
      },
      applications: byApp,
      containers: containerTraffic
    });
  } catch (err) {
    return res.status(500).json({
      status: "error",
      error: "Falha ao ler trafego de rede dos containers",
      detail: String(err.message || err)
    });
  }
});

app.get("/api/services", async (req, res) => {
  try {
    const containersRaw = await dockerApi("/containers/json?all=1");
    const list = Array.isArray(containersRaw) ? containersRaw : [];

    const checks = await Promise.all(
      list.map(async (c) => ({
        container: c,
        exists: await dockerContainerExists(c?.Id)
      }))
    );
    const realContainers = checks
      .filter((entry) => entry.exists)
      .filter((entry) => !isMonitorOrphanContainer(entry.container))
      .map((entry) => entry.container);

    const servicesList = realContainers
      .map((c) => {
        const name = getContainerName(c);
        const online = String(c?.State || "").toLowerCase() === "running";
        const image = String(c?.Image || "");
        const network = String(c?.HostConfig?.NetworkMode || "");
        return {
          name,
          online,
          detail: "Imagem: " + image + (network ? " | Rede: " + network : "")
        };
      })
      .filter((s) => s.name)
      .sort((a, b) => {
        if (a.online !== b.online) return a.online ? -1 : 1;
        return a.name.localeCompare(b.name, "pt-BR");
      });

    const services = {};
    servicesList.forEach((item) => {
      services[item.name] = item.online;
    });

    return res.json({
      status: "ok",
      services,
      items: servicesList
    });
  } catch (err) {
    return res.status(500).json({
      status: "error",
      error: "Falha ao ler status dos servicos",
      detail: String(err.message || err)
    });
  }
});

app.get("/api/firebird", async (req, res) => {
  const start = Date.now();
  try {
    const containersRaw = await dockerApi("/containers/json?all=1");
    const fb = (containersRaw || []).find((c) =>
      Array.isArray(c.Names) &&
      c.Names.some((n) => n.replace(/^\//, "") === "firebird25")
    );

    const running = Boolean(fb && fb.State === "running");
    if (!running) {
      return res.json({
        status: "ok",
        ok: false,
        response_ms: null,
        version: null,
        detail: "Container firebird25 nao esta em execucao"
      });
    }

    const image = fb.Image || "";
    const versionMatch = image.match(/:(.+)$/);
    const version = versionMatch ? versionMatch[1] : image;

    return res.json({
      status: "ok",
      ok: true,
      response_ms: Date.now() - start,
      version,
      detail: "Firebird container ativo"
    });
  } catch (err) {
    return res.status(500).json({
      status: "error",
      ok: false,
      response_ms: null,
      version: null,
      detail: String(err.message || err)
    });
  }
});

app.get("/api/tunnel", async (req, res) => {
  try {
    const containersRaw = await dockerApi("/containers/json?all=1");
    const cf = (containersRaw || []).find((c) =>
      Array.isArray(c.Names) &&
      c.Names.some((n) => {
        const clean = n.replace(/^\//, "");
        return clean === "cloudflared" || clean === "cloudflared-portal-eco";
      })
    );

    const running = Boolean(cf && cf.State === "running");

        let registered = false;
    try {
      const socketPath = "/var/run/docker.sock";
      const targetName = Array.isArray(cf?.Names) && cf.Names[0]
        ? cf.Names[0].replace(/^\//, "")
        : "cloudflared";
      const logs = await new Promise((resolve, reject) => {
        const req = http.request(
          {
            socketPath,
            path: `/containers/${encodeURIComponent(targetName)}/logs?stdout=1&stderr=1&tail=200`,
            method: "GET"
          },
          (resp) => {
            let body = "";
            resp.on("data", (chunk) => {
              body += chunk.toString("utf8");
            });
            resp.on("end", () => resolve(body));
          }
        );
        req.on("error", reject);
        req.end();
      });
      registered = /Registered tunnel connection/i.test(logs);
    } catch (_) {
      registered = false;
    }

    return res.json({
      status: "ok",
      running,
      registered,
      latency_ms: null
    });
  } catch (err) {
    return res.status(500).json({
      status: "error",
      running: false,
      registered: false,
      latency_ms: null,
      detail: String(err.message || err)
    });
  }
});

app.listen(PORT, () => {
  if (AUTH_FAIL_ON_INSECURE_DEFAULTS) {
    if (AUTH_PASSWORD === "change-me") {
      console.error("AUTH_PASSWORD esta no valor padrao; ajuste antes de iniciar.");
      process.exit(1);
    }
    if (AUTH_TOKEN_SECRET === "change-this-token-secret") {
      console.error("AUTH_TOKEN_SECRET esta no valor padrao; ajuste antes de iniciar.");
      process.exit(1);
    }
  }

  if (AUTH_ENABLED) {
    try {
      authStore.ensureUser(AUTH_USERNAME, AUTH_PASSWORD, "admin");
      console.log(`auth db ready at ${AUTH_DB_PATH}; admin seed: ${AUTH_USERNAME}`);
    } catch (err) {
      console.error("failed to initialize auth store:", err.message || err);
      process.exit(1);
    }
  }
  if (AUTH_ENABLED && AUTH_PASSWORD === "change-me") {
    console.warn("AUTH_PASSWORD esta no valor padrao; altere em producao.");
  }
  if (AUTH_ENABLED && AUTH_TOKEN_SECRET === "change-this-token-secret") {
    console.warn("AUTH_TOKEN_SECRET esta no valor padrao; altere em producao.");
  }
  if (ALLOWED_ORIGINS.length > 0) {
    console.log("cors allowlist ativo:", ALLOWED_ORIGINS.join(", "));
  } else {
    console.warn("ALLOWED_ORIGINS vazio; CORS para origens externas esta desativado.");
  }
  console.log(`infra-dashboard-backend running on port ${PORT}`);
});
