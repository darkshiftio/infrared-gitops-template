// The actor check's self-test container (scripts/substrate-actor-check.sh):
// what a container beside the runner in one actor can see and reach, printed
// as ACTOR-CHECK lines on stdout, which the worker pod's log keeps. It waits
// first, so the check has started the runner's one step before it tries to.
const fs = require("node:fs");
const http = require("node:http");
const tls = require("node:tls");

// One line a fact, ended by ;; and with no quote, backslash, semicolon or line
// break in it, so the worker's log keeps it whole whatever it wraps it in.
const clean = (s) => String(s).replace(/["\\;\n\r\t]/g, " ").replace(/ +/g, " ").trim();
const out = (k, v) => console.log(`ACTOR-CHECK ${k} ${clean(Array.isArray(v) ? v.join(" | ") : v)} ;;`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function req(method, path, body, headers = {}) {
  return new Promise((resolve) => {
    const r = http.request({ host: "127.0.0.1", port: 80, method, path, headers, timeout: 10000 }, (res) => {
      res.resume();
      res.on("end", () => resolve(String(res.statusCode)));
    });
    r.on("error", (e) => resolve(`error:${e.code || e.message}`));
    r.on("timeout", () => r.destroy(new Error("timeout")));
    if (body) r.write(body);
    r.end();
  });
}

function tlsTo(host) {
  return new Promise((resolve) => {
    const s = tls.connect({ host, port: 443, servername: host, timeout: 10000 }, () => {
      resolve(`connected:${s.authorized ? "verified" : "unverified"}`);
      s.end();
    });
    s.on("error", (e) => resolve(`error:${e.code || e.message}`));
    s.on("timeout", () => s.destroy(Object.assign(new Error("timeout"), { code: "TIMEOUT" })));
  });
}

async function round(n) {
  out("round", String(n));
  out("whoami", `${process.getuid()}:${process.getgid()} pid ${process.pid}`);
  const pids = fs.readdirSync("/proc").filter((d) => /^\d+$/.test(d));
  out(
    "processes",
    pids.map((p) => {
      try {
        return `${p}:${clean(fs.readFileSync(`/proc/${p}/cmdline`).toString().replace(/\0/g, " ")).slice(0, 60)}`;
      } catch {
        return `${p}:?`;
      }
    }),
  );
  let readable = 0;
  let canary = false;
  let mem = 0;
  for (const p of pids) {
    if (Number(p) === process.pid) continue;
    try {
      const env = fs.readFileSync(`/proc/${p}/environ`);
      readable++;
      if (env.includes("ACTORCHECK")) canary = true;
    } catch {}
    try {
      fs.closeSync(fs.openSync(`/proc/${p}/mem`, "r"));
      mem++;
    } catch {}
  }
  out("other-environ-readable", String(readable));
  out("canary-seen", String(canary));
  out("other-mem-openable", String(mem));
  out("second-step", await req("POST", "/steps", JSON.stringify({ id: "intruder", pollToken: "x".repeat(64), spec: {} }),
    { "content-type": "application/json" }));
  out("poll-without-token", await req("GET", `/steps/${process.env.STEP_ID}`));
  out("poll-wrong-token", await req("GET", `/steps/${process.env.STEP_ID}`, null, { authorization: `Bearer ${"y".repeat(64)}` }));
  out("egress-listed", await tlsTo("api.anthropic.com"));
  out("egress-unlisted", await tlsTo("example.com"));
}

(async () => {
  await sleep(Number(process.env.SELFTEST_WAIT_MS || 90000));
  for (let n = 1; n <= 3; n++) {
    await round(n);
    await sleep(20000);
  }
  out("done", "true");
  // Stay up: the check deletes the actor.
  for (;;) await sleep(3600000);
})();
