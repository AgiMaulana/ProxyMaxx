// ProxyMaxx — popup.
//
// Reads one status object from the service worker and renders it. Every verdict here is
// derived from something real: the browser's effective proxy setting, its control level,
// or live state from the Mac app. Nothing is guessed.
//
// If the worker cannot be reached — it failed to register, or it is being reloaded — this
// does not show a blank panel. It reads what it can from its own context and says what is
// broken. A diagnostics panel that shows nothing is worse than one that shows less.

const bootWarning = document.getElementById("boot");

/// Put the reason on screen. Without this, an uncaught error leaves the panel showing its
/// placeholder HTML, which reads exactly like a worker that never answered.
function reportStartupFailure(message) {
  if (!bootWarning) return;
  bootWarning.hidden = false;
  bootWarning.textContent = `The popup script stopped: ${message}`;
}

window.addEventListener("error", (event) => reportStartupFailure(event.message ?? "unknown error"));
window.addEventListener("unhandledrejection", (event) => {
  reportStartupFailure(String(event.reason?.message ?? event.reason));
});

const elements = {
  appState: document.getElementById("app-state"),
  version: document.getElementById("version"),
  capture: document.getElementById("capture"),
  captureDetail: document.getElementById("capture-detail"),
  mode: document.getElementById("fact-mode"),
  control: document.getElementById("fact-control"),
  app: document.getElementById("fact-app"),
  ca: document.getElementById("fact-ca"),
  localhost: document.getElementById("opt-localhost"),
  port: document.getElementById("opt-port"),
  error: document.getElementById("error"),
  checks: document.getElementById("checks"),
};

const CONTROL_LABELS = {
  controlled_by_this_extension: "this extension",
  controllable_by_this_extension: "free (not set by anyone)",
  controlled_by_other_extensions: "another extension",
  not_controllable: "a policy or the command line",
};

function check(verdict, state, text) {
  return { verdict, state, text };
}

function buildChecks(status) {
  const { mode, levelOfControl, app, captureLocalhost } = status;
  const connected = app.connected;
  const state = connected ? app.state : null;
  const checks = [];
  const port = status.effectivePort ?? status.port;

  checks.push(
    mode === "fixed_servers"
      ? check("Applied", "ok", `This browser sends HTTP and HTTPS to 127.0.0.1:${port}.`)
      : check("Not applied", "warn", `This browser resolves proxies as "${mode}". Turn capture on.`)
  );

  checks.push(
    levelOfControl === "controlled_by_this_extension"
      ? check("This extension", "ok", "The proxy setting is ours to change.")
      : check(
          "Owner",
          levelOfControl === "controllable_by_this_extension" ? "muted" : "warn",
          `The proxy setting is controlled by ${CONTROL_LABELS[levelOfControl] ?? levelOfControl}.`
        )
  );

  // Only ever claim what the app actually told us. "Cannot be reached" and "nothing is
  // listening" are different states, and the difference is the whole diagnosis.
  if (status.weOwnProxy && !connected) {
    checks.push(
      check("Unverified", "warn", `Capture is on, and the app cannot be reached to confirm anything accepts connections on 127.0.0.1:${port}. If pages fail to load, turn capture off.`)
    );
  } else if (status.weOwnProxy && connected && state.proxyListening === false) {
    checks.push(
      check("Nothing listening", "warn", `The app is running but nothing accepts connections on 127.0.0.1:${state.httpPort}, so every request in this browser fails. Check the port in the app.`)
    );
  } else if (status.weOwnProxy && connected) {
    checks.push(
      check("Listening", "ok", `The app accepts connections on 127.0.0.1:${state.httpPort}.`)
    );
  }

  // Worth stating plainly, because it is the failure that looks like a broken extension: a
  // stored port that no longer matches where the app actually listens.
  if (connected && status.effectivePort !== status.port) {
    checks.push(
      check("App's port", "muted", `The app listens on ${state.httpPort}, so the browser is pointed there. The port field above is only the fallback for when the app cannot be asked.`)
    );
  }

  if (!connected) {
    checks.push(check("Unknown", "muted", `The app is not answering: ${app.reason}`));
  } else if (state.caTrusted) {
    checks.push(check("Trusted", "ok", "The app's root CA is trusted, so HTTPS can be decrypted."));
  } else {
    checks.push(check("Missing", "warn", "Install and trust the root CA in the app. Without it every HTTPS request fails instead of appearing."));
  }

  checks.push(
    check("Handled", "muted", "Chrome will not use QUIC while a non-QUIC proxy is set, so HTTP/3 falls back to TCP here. Other apps on this Mac are unaffected.")
  );

  checks.push(
    captureLocalhost
      ? check("On", "ok", "Loopback traffic is sent to the app.")
      : check("Bypassed", "muted", "Chrome bypasses loopback by default; http://localhost never reaches the proxy.")
  );

  checks.push(
    check("Not ours", "muted", "Connections opened before the switch keep their old route until the tab is reloaded.")
  );

  checks.push(
    check("By design", "muted", "Hosts that pin a certificate are never decrypted, with or without a trusted CA.")
  );

  return checks;
}

function showError(text) {
  elements.error.hidden = false;
  elements.error.textContent = text;
}

function renderChecks(checks) {
  elements.checks.replaceChildren(
    ...checks.map(({ verdict, state: statusClass, text }) => {
      const item = document.createElement("li");
      item.className = statusClass;
      const label = document.createElement("span");
      label.className = "verdict";
      label.textContent = verdict;
      const body = document.createElement("span");
      body.textContent = text;
      item.append(label, body);
      return item;
    })
  );
}

function renderFacts(status) {
  const connected = status.app.connected;
  const state = connected ? status.app.state : null;
  const port = status.effectivePort ?? status.port;
  // An app that is running but not reachable is a different state from one that is down, so
  // the label distinguishes them.
  const reachable = connected;

  elements.appState.textContent = connected ? "App connected" : "App not answering";
  elements.appState.classList.toggle("ok", connected);

  elements.mode.textContent = status.mode;
  elements.control.textContent = CONTROL_LABELS[status.levelOfControl] ?? status.levelOfControl;
  elements.app.textContent = !connected
    ? "not reachable"
    : state.proxyListening === false
      ? `nothing accepting connections on ${state.httpPort}`
      : `listening on ${state.httpPort}${state.socksPort ? `, SOCKS5 ${state.socksPort}` : ""}`;
  elements.ca.textContent = connected ? (state.caTrusted ? "ready" : "root CA not trusted") : "unknown";

  elements.localhost.checked = status.captureLocalhost;
  elements.port.value = String(status.port);

  elements.capture.setAttribute("aria-pressed", String(status.weOwnProxy));

  if (!status.weOwnProxy) {
    elements.captureDetail.textContent = "Off — the browser's own proxy settings apply";
  } else if (!reachable) {
    elements.captureDetail.textContent = `On — 127.0.0.1:${port}, unconfirmed`;
  } else if (state.proxyListening === false) {
    elements.captureDetail.textContent = `On — nothing answering on 127.0.0.1:${port}`;
  } else {
    elements.captureDetail.textContent = `On — 127.0.0.1:${port}`;
  }
}

function render(status) {
  if (!status || status.error) {
    showError(status?.error ?? "The extension could not read its own state.");
    elements.appState.textContent = "Unavailable";
    return;
  }

  renderFacts(status);

  if (status.workerFailure) {
    // The worker is gone, so nothing can be written. Say so, disable the controls that
    // would silently do nothing, and keep the facts read from here.
    elements.appState.textContent = "Worker not running";
    elements.appState.classList.remove("ok");
    elements.capture.disabled = true;
    elements.localhost.disabled = true;
    elements.port.disabled = true;

    const detail = status.workerFailure.initFailure
      ? ` The worker reported: ${status.workerFailure.initFailure}`
      : "";
    showError(
      `${status.workerFailure.reason}${detail} ` +
        "Open chrome://extensions, find ProxyMaxx, and press Reload. If an Errors button appears next to it, open that and copy the message."
    );
  } else {
    elements.capture.disabled = false;
    elements.localhost.disabled = false;
    elements.port.disabled = false;
    elements.error.hidden = true;
    elements.error.title = "";
  }

  if (status.lastProxyError) {
    const error = status.lastProxyError;
    const when = new Date(error.at);
    showError(`Proxy error at ${when.toLocaleTimeString()}: ${error.error}${error.details ? ` — ${error.details}` : ""}`);
    elements.error.title = "Click to dismiss";
  }

  renderChecks(buildChecks(status));
}

// MARK: - Talking to the worker

/// Resolve or reject within `ms`. A hung channel is worse than a failed one: with no
/// deadline the popup sits on "Checking…" forever and says nothing.
function withTimeout(promise, ms, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${label} did not answer within ${ms} ms.`)), ms);
    promise.then(
      (value) => { clearTimeout(timer); resolve(value); },
      (error) => { clearTimeout(timer); reject(error); }
    );
  });
}

async function readStored(key, fallback) {
  try {
    const stored = await withTimeout(chrome.storage.local.get({ [key]: fallback }), 800, "chrome.storage");
    return stored[key];
  } catch {
    return fallback;
  }
}

/// The browser's effective proxy setting, read directly. This is an extension API, so it
/// works in the popup whether or not the worker is alive.
async function readProxySetting() {
  try {
    const promise = new Promise((resolve) => {
      chrome.proxy.settings.get({ incognito: false }, (value) => resolve(chrome.runtime.lastError ? null : value));
    });
    return await withTimeout(promise, 800, "chrome.proxy.settings");
  } catch {
    return null;
  }
}

/// Read what this context can see on its own. Used when the worker is unreachable, so the
/// panel can still name the proxy setting and its owner instead of showing nothing.
async function degradedStatus(reason) {
  const setting = await readProxySetting();

  return {
    port: await readStored("port", 9090),
    captureLocalhost: await readStored("captureLocalhost", false),
    weOwnProxy: await readStored("weOwnProxy", false),
    lastProxyError: await readStored("lastProxyError", null),
    mode: setting?.value?.mode ?? "unknown",
    levelOfControl: setting?.levelOfControl ?? "unknown",
    app: { connected: false, reason: "The background worker is not running, so the app cannot be asked." },
    workerFailure: { reason, initFailure: await readStored("initFailure", null) },
  };
}

const WORKER_TIMEOUT_LABEL = "The background worker";

async function send(command, extra = {}, attempt = 1) {
  // The first attempt waits like a person would; the retry is short, because a worker that
  // is merely not registered yet fails fast. Two long waits would leave the panel staring
  // at "Checking…" for five seconds before it admits anything is wrong.
  const timeout = attempt === 1 ? 1800 : 800;

  let status;
  try {
    status = await withTimeout(chrome.runtime.sendMessage({ cmd: command, ...extra }), timeout, WORKER_TIMEOUT_LABEL);
  } catch (error) {
    const reason = String(error?.message ?? error);
    if (attempt === 1) {
      // Covers the first message racing the worker's registration, and the worker being
      // torn down mid-request.
      await new Promise((resolve) => setTimeout(resolve, 300));
      return send(command, extra, 2);
    }
    render(await degradedStatus(reason));
    return;
  }

  if (status === undefined) {
    render(await degradedStatus("The background worker answered with nothing."));
    return;
  }

  render(status);
}

// MARK: - Wiring

// Always visible, before anything can fail: if this number is not the version you just
// built, the browser is still running the previous files and no other result means anything.
try {
  elements.version.textContent = `v${chrome.runtime.getManifest().version}`;
} catch {
  // Leave it blank rather than blocking the panel.
}

elements.capture.addEventListener("click", () => {
  send(elements.capture.getAttribute("aria-pressed") === "true" ? "disable" : "enable");
});

elements.localhost.addEventListener("change", () => {
  send("setLocalhost", { value: elements.localhost.checked });
});

elements.port.addEventListener("change", () => {
  send("setPort", { value: elements.port.value });
});

elements.error.addEventListener("click", () => {
  send("clearError");
});

// Everything above is synchronous, so reaching this line means the script ran to the end.
// Anything that failed before it left the placeholder text on screen instead of silence.
if (bootWarning) bootWarning.hidden = true;

send("status");
