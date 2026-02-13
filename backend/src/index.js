const express = require("express");
const cors = require("cors");
const os = require("os");
const { exec } = require("child_process");
const http = require("http");
const fs = require("fs");

const app = express();
const PORT = process.env.PORT || 4000;

app.use(cors());
app.use(express.json());
app.use(express.static("/workspace/frontend"));


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
  console.log(`infra-dashboard-backend running on port ${PORT}`);
});
