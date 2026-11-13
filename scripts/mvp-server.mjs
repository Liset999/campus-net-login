import http from "node:http";
import https from "node:https";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn, execFile } from "node:child_process";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const APP_FILE = path.join(ROOT, "app", "index.html");
const DIAGNOSTIC_FILE = path.join(ROOT, "diagnostics", "latest.json");
const HOST = "127.0.0.1";
const PORT = Number(process.env.CAMPUS_MVP_PORT || getArgValue("--port") || 0);

function getArgValue(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : "";
}

function sendJson(response, status, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "Content-Length": Buffer.byteLength(body)
  });
  response.end(body);
}

function sendText(response, status, body, contentType) {
  response.writeHead(status, {
    "Content-Type": contentType,
    "Cache-Control": "no-store",
    "Content-Length": Buffer.byteLength(body)
  });
  response.end(body);
}

async function readJson(request) {
  const chunks = [];
  let size = 0;

  for await (const chunk of request) {
    size += chunk.length;
    if (size > 64 * 1024) {
      throw new Error("请求内容过大");
    }
    chunks.push(chunk);
  }

  if (!chunks.length) return {};
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function runPowerShell(scriptArgs) {
  return new Promise((resolve, reject) => {
    const command = process.platform === "win32" ? "pwsh.exe" : "pwsh";
    const child = spawn(command, [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      ...scriptArgs
    ], {
      cwd: ROOT,
      windowsHide: true
    });

    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error("诊断超过 30 秒仍未完成"));
    }, 30000);

    child.stdout.on("data", chunk => { stdout += chunk.toString(); });
    child.stderr.on("data", chunk => { stderr += chunk.toString(); });

    child.on("error", error => {
      clearTimeout(timer);
      reject(error);
    });

    child.on("close", code => {
      clearTimeout(timer);
      if (code !== 0) {
        reject(new Error(stderr.trim() || stdout.trim() || "PowerShell 诊断失败"));
        return;
      }
      resolve({ stdout, stderr });
    });
  });
}

async function runDiagnose(targetSsid) {
  const target = String(targetSsid || "").trim();
  if (!target || target.length > 80) {
    throw new Error("SSID 不能为空或过长");
  }

  await runPowerShell([
    "-File",
    path.join(ROOT, "scripts", "diagnose.ps1"),
    "-TargetSsid",
    target,
    "-OutputPath",
    DIAGNOSTIC_FILE
  ]);

  return JSON.parse(await fs.readFile(DIAGNOSTIC_FILE, "utf8"));
}

function getCurrentIp(diagnosis) {
  const addresses = diagnosis && diagnosis.ip && diagnosis.ip.addresses;
  const list = Array.isArray(addresses) ? addresses : (addresses ? [addresses] : []);
  if (!list.length) return "";
  return String(list[0]);
}

function getOperatorSuffix(operator, customOperator) {
  if (operator === "cmcc") return "@cmcc";
  if (operator === "ctcc") return "@njxy";
  if (operator === "custom") {
    const value = String(customOperator || "").trim();
    if (!value) return "";
    return value.startsWith("@") ? value : "@" + value;
  }
  return "";
}

function parsePortalBody(body) {
  const match = body.match(/^[^(]+\(([\s\S]*)\)\s*;?\s*$/);
  if (!match) return null;

  try {
    return JSON.parse(match[1]);
  } catch {
    return null;
  }
}

function requestLogin(port, account, password, suffix, wlanIp) {
  return new Promise(resolve => {
    const loginUrl = new URL("https://p.njupt.edu.cn:" + port + "/eportal/portal/login");
    const query = new URLSearchParams({
      callback: "dr1003",
      login_method: "1",
      user_account: ",0," + account + suffix,
      user_password: password,
      wlan_user_ip: wlanIp,
      wlan_user_ipv6: "",
      wlan_user_mac: "000000000000",
      wlan_ac_ip: "",
      wlan_ac_name: "",
      jsVersion: "4.1.3",
      terminal_type: "1",
      lang: "zh-cn",
      v: String(Date.now())
    });
    loginUrl.search = query.toString();

    const request = https.get(loginUrl, {
      rejectUnauthorized: false,
      headers: {
        "User-Agent": "campus-net-login/0.1",
        "Accept": "application/javascript, */*"
      }
    }, response => {
      const chunks = [];
      response.on("data", chunk => {
        if (Buffer.concat(chunks).length < 128 * 1024) chunks.push(chunk);
      });
      response.on("end", () => {
        const body = Buffer.concat(chunks).toString("utf8");
        const payload = parsePortalBody(body);
        const message = payload && (payload.msg || payload.message);
        const result = payload && payload.result;
        const success = result === 1 || result === "1" || /成功|success|online/i.test(String(message || ""));
        resolve({
          port,
          success,
          statusCode: response.statusCode || 0,
          message: message || (success ? "门户接受了登录结果" : "门户返回了无法识别的结果")
        });
      });
    });

    request.setTimeout(8000, () => {
      request.destroy(new Error("连接认证端口超时"));
    });

    request.on("error", error => {
      resolve({
        port,
        success: false,
        statusCode: 0,
        message: "认证端口不可达：" + error.code
      });
    });
  });
}

async function loginToNjupt(body) {
  const account = String(body.account || "").trim();
  const password = String(body.password || "");
  const targetSsid = String(body.targetSsid || "").trim();

  if (!account || !password) {
    throw new Error("学号和密码不能为空");
  }
  if (!targetSsid) {
    throw new Error("SSID 不能为空");
  }

  const diagnosis = await runDiagnose(targetSsid);
  const wifi = diagnosis.current_wifi || {};
  if (wifi.target_matches !== true) {
    throw new Error("当前真实 SSID 不是 " + targetSsid + "，没有提交登录请求");
  }

  const wlanIp = getCurrentIp(diagnosis);
  if (!wlanIp) {
    throw new Error("当前没有拿到 IPv4 地址，没有提交登录请求");
  }

  const suffix = getOperatorSuffix(body.operator, body.customOperator);
  const ports = [804, 802, 803, 801];
  let lastResult = null;

  for (const port of ports) {
    const result = await requestLogin(port, account, password, suffix, wlanIp);
    lastResult = result;
    if (result.success) {
      return {
        success: true,
        message: "南邮认证成功（入口 " + port + "）",
        port
      };
    }
    if (result.statusCode >= 200 && result.statusCode < 500 && result.statusCode !== 404) {
      return {
        success: false,
        message: result.message || "门户拒绝了登录请求",
        port
      };
    }
  }

  return {
    success: false,
    message: lastResult ? lastResult.message : "南邮认证入口均不可达"
  };
}

function isAllowedPortal(rawUrl) {
  const parsed = new URL(rawUrl);
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return false;
  const host = parsed.hostname.toLowerCase();
  if (host === "p.njupt.edu.cn" || host.endsWith(".njupt.edu.cn")) return true;
  if (/^10\.(?:[0-9]{1,3}\.){2}[0-9]{1,3}$/.test(host)) return true;
  if (/^192\.168\.(?:[0-9]{1,3}\.)[0-9]{1,3}$/.test(host)) return true;
  if (/^172\.(1[6-9]|2[0-9]|3[01])\.(?:[0-9]{1,3}\.)[0-9]{1,3}$/.test(host)) return true;
  return false;
}

function openPortal(rawUrl) {
  return new Promise((resolve, reject) => {
    if (!isAllowedPortal(rawUrl)) {
      reject(new Error("只允许打开南邮门户或校园网私网地址"));
      return;
    }

    execFile("rundll32.exe", ["url.dll,FileProtocolHandler", rawUrl], {
      windowsHide: true
    }, error => {
      if (error) reject(new Error("系统没有成功打开浏览器"));
      else resolve();
    });
  });
}

async function serve(request, response) {
  const url = new URL(request.url, "http://" + HOST + ":" + PORT);

  if (request.method === "GET" && url.pathname === "/") {
    const html = await fs.readFile(APP_FILE);
    sendText(response, 200, html, "text/html; charset=utf-8");
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/health") {
    sendJson(response, 200, {
      ok: true,
      app: "campus-net-login",
      version: "mvp-0.1",
      adapter: "njupt",
      proxy_mode: "keep-user-proxy"
    });
    return;
  }

  if (request.method !== "POST") {
    sendJson(response, 404, { message: "接口不存在" });
    return;
  }

  let body;
  try {
    body = await readJson(request);
  } catch (error) {
    sendJson(response, 400, { message: "请求 JSON 无效" });
    return;
  }

  try {
    if (url.pathname === "/api/diagnose") {
      sendJson(response, 200, await runDiagnose(body.targetSsid));
      return;
    }

    if (url.pathname === "/api/open-portal") {
      const rawUrl = String(body.url || "https://p.njupt.edu.cn:804/eportal/portal/");
      await openPortal(rawUrl);
      sendJson(response, 200, { success: true });
      return;
    }

    if (url.pathname === "/api/login") {
      sendJson(response, 200, await loginToNjupt(body));
      return;
    }

    sendJson(response, 404, { message: "接口不存在" });
  } catch (error) {
    sendJson(response, 400, { message: error.message || "请求失败" });
  }
}

const server = http.createServer((request, response) => {
  serve(request, response).catch(error => {
    sendJson(response, 500, { message: "MVP 服务错误：" + error.message });
  });
});

server.listen(PORT, HOST, () => {
  const address = server.address();
  const actualPort = address && typeof address === "object" ? address.port : PORT;
  fs.writeFile(
    path.join(ROOT, "diagnostics", "mvp-port.json"),
    JSON.stringify({ port: actualPort, started_at_utc: new Date().toISOString() }),
    "utf8"
  ).catch(() => {});
  console.log("Campus Link MVP listening on http://" + HOST + ":" + actualPort);
});



