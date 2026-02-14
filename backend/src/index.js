const express = require("express");
const cors = require("cors");
const os = require("os");
const { exec } = require("child_process");
const http = require("http");
const fs = require("fs");
const crypto = require("crypto");

const app = express();
const PORT = process.env.PORT || 4000;
const AUTH_ENABLED = String(process.env.AUTH_ENABLED || "true").toLowerCase() !== "false";
const AUTH_USERNAME = process.env.AUTH_USERNAME || "admin";
const AUTH_PASSWORD = process.env.AUTH_PASSWORD || "change-me";
const AUTH_TOKEN_SECRET = process.env.AUTH_TOKEN_SECRET || "change-this-token-secret";
const AUTH_TOKEN_TTL_SECONDS = Number(process.env.AUTH_TOKEN_TTL_SECONDS || 60 * 60 * 12);

app.use(cors());
app.use(express.json());
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

const signAuthToken = (username) => {
  const header = { alg: "HS256", typ: "JWT" };
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    sub: username,
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

const safeEquals = (a, b) => {
  const left = Buffer.from(String(a || ""));
  const right = Buffer.from(String(b || ""));
  if (left.length !== right.length) return false;
  return crypto.timingSafeEqual(left, right);
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
    exec("df -B1 / | tail -1", (err, stdout) => {
      if (err || !stdout) {
        return resolve({ total: 0, used: 0, percent: 0 });
      }
      const cols = stdout.trim().split(/\s+/);
      const total = Number(cols[1] || 0);
      const used = Number(cols[2] || 0);
      const percent = total > 0 ? Number(((used / total) * 100).toFixed(2)) : 0;
      resolve({ total, used, percent });
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

  if (!safeEquals(username, AUTH_USERNAME) || !safeEquals(password, AUTH_PASSWORD)) {
    return res.status(401).json({
      status: "error",
      error: "credenciais invalidas"
    });
  }

  const token = signAuthToken(username);
  return res.json({
    status: "ok",
    token,
    token_type: "Bearer",
    expires_in: Math.max(60, Number(AUTH_TOKEN_TTL_SECONDS) || 0),
    user: { username }
  });
});

app.use("/api", apiAuthMiddleware);

app.get("/api/auth/me", (req, res) => {
  return res.json({
    status: "ok",
    auth_enabled: AUTH_ENABLED,
    user: { username: req.auth?.sub || AUTH_USERNAME }
  });
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
    const items = (containersRaw || []).map((c) => ({
      name: (Array.isArray(c.Names) && c.Names[0] ? c.Names[0].replace(/^\//, "") : ""),
      image: c.Image || "",
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

app.get("/api/services", async (req, res) => {
  const targets = ["chalana-api", "firebird25", "nginx-proxy-manager", "cloudflared"];
  try {
    const containersRaw = await dockerApi("/containers/json?all=1");
    const map = new Map();
    (containersRaw || []).forEach((c) => {
      const name = Array.isArray(c.Names) && c.Names[0] ? c.Names[0].replace(/^\//, "") : "";
      map.set(name, c.State === "running");
    });

    const services = {};
    targets.forEach((name) => {
      services[name] = Boolean(map.get(name));
    });

    return res.json({
      status: "ok",
      services
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
      c.Names.some((n) => n.replace(/^\//, "") === "cloudflared")
    );

    const running = Boolean(cf && cf.State === "running");

        let registered = false;
    try {
      const socketPath = "/var/run/docker.sock";
      const logs = await new Promise((resolve, reject) => {
        const req = http.request(
          {
            socketPath,
            path: "/containers/cloudflared/logs?stdout=1&stderr=1&tail=200",
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
  if (AUTH_ENABLED && AUTH_PASSWORD === "change-me") {
    console.warn("AUTH_PASSWORD esta no valor padrao; altere em producao.");
  }
  if (AUTH_ENABLED && AUTH_TOKEN_SECRET === "change-this-token-secret") {
    console.warn("AUTH_TOKEN_SECRET esta no valor padrao; altere em producao.");
  }
  console.log(`infra-dashboard-backend running on port ${PORT}`);
});
