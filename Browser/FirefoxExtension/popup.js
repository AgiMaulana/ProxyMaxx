// ProxyMaxx — Firefox popup.
//
// Reads one status object from the background page and renders it. Every verdict here is
// derived from something real: the browser's proxy setting, or live state from the Mac app.
// Nothing is guessed.
//
// If the background page cannot be reached — it failed to register, or it is being
// reloaded — this does not show a blank panel. It reads what it can from its own context
// and says what is broken. A diagnostics panel that shows nothing is worse than one that
// shows less.

const bootWarning = document.getElementById("boot");

/// Put the reason on screen. Without this, an uncaught error leaves the panel showing its
/// placeholder HTML, which reads exactly like a page that never answered.
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
  app: document.getElementById("fact-app"),
  ca: document.getElementById("fact-ca"),
  port: document.getElementById("opt-port"),
  error: document.getElementById("error"),
  retry: document.getElementById("retry"),
  checks: document.getElementById("checks"),
};

/// How to describe where the port in use came from, so a number nothing can account for is
/// never presented as though it had been read from the app.
const PORT_ORIGINS = {
  app: "the port the app reported",
  last: "the port the app last reported",
  manual: "the port you set",
};

function check(verdict, state, text) {
  return { verdict, state, text };
}

/// The one thing a person can do about a bridge that is not answering, named in the panel
/// because the failure is otherwise invisible: nothing about the browser or the extension
/// looks wrong.
const BRIDGE_FIX =
  "Open ProxyMaxx and press Install Browser Extension…, then press Reload on this extension's card in about:addons.";

function buildChecks(status) {
  const { proxyType, app } = status;
  const connected = app.connected;
  const state = connected ? app.state : null;
  const checks = [];
  const port = status.effectivePort;

  checks.push(
    status.weOwnProxy && port !== null
      ? check("Applied", "ok", `This browser sends HTTP and HTTPS to 127.0.0.1:${port}.`)
      : check("Not applied", "warn", `This browser resolves proxies as "${proxyType}". Turn capture on.`)
  );

  // Only ever claim what the app actually told us. "Cannot be reached" and "nothing is
  // listening" are different states, and the difference is the whole diagnosis.
  if (status.weOwnProxy && !connected && port !== null) {
  checks.push(
    check("Unverified", "warn", `Capture is on at 127.0.0.1:${port}, ${PORT_ORIGINS[status.portSource] ?? "a remembered port"}, but the app is not answering now to confirm anything is listening there. If pages fail to load, turn capture off.`)
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

  if (connected && status.port !== null && status.effectivePort !== status.port) {
    checks.push(
      check("App's port", "muted", `The app listens on ${state.httpPort}, so the browser is pointed there. The port field above is only the fallback for when the app cannot be asked.`)
    );
  }

  if (status.weOwnProxy && status.portSource === "last") {
    checks.push(
      check("Remembered", "muted", `The app is not answering, so the browser is still pointed at ${status.effectivePort}, the last port it reported.`)
    );
  }

  if (status.weOwnProxy && port === null) {
    checks.push(
      check("No port", "warn", `Capture has no confirmed port, so this browser was left on its own settings. ${BRIDGE_FIX}`)
    );
  }

  if (!connected) {
    checks.push(check("Bridge", "warn", `The app is not answering: ${app.reason} The port, the CA verdict and the listener check all come over this bridge. ${BRIDGE_FIX}`));
  } else if (state.caTrusted) {
    checks.push(check("Trusted", "ok", "The app's root CA is trusted, so HTTPS can be decrypted."));
  } else {
    checks.push(check("Missing", "warn", "Install and trust the root CA in the app. Without it every HTTPS request fails instead of appearing."));
  }

  checks.push(
    check("Session only", "muted", "The proxy value stays set until this page turns it off or the browser is reset; it is worth pressing disable before quitting if you want the pre-capture behaviour back for certain.")
  );

  checks.push(
    check("Direct too", "muted", "Firefox's proxy value has no loopback exception, so http://localhost is sent to the app along with everything else."),
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
  const port = status.effectivePort;

  elements.appState.textContent = connected ? "App connected" : "App not answering";
  elements.appState.classList.toggle("ok", connected);

  elements.mode.textContent = status.weOwnProxy && port !== null ? "manual" : status.proxyType;
  elements.app.textContent = !connected
    ? "not reachable"
    : state.proxyListening === false
      ? `nothing accepting connections on ${state.httpPort}`
      : `listening on ${state.httpPort}${state.socksPort ? `, SOCKS5 ${state.socksPort}` : ""}`;
  elements.ca.textContent = connected ? (state.caTrusted ? "ready" : "root CA not trusted") : "unknown";

  elements.port.value = status.port === null ? "" : String(status.port);

  elements.capture.setAttribute("aria-pressed", String(status.weOwnProxy));

  if (!status.weOwnProxy) {
    elements.captureDetail.textContent = "Off — the browser's own proxy settings apply";
  } else if (port === null) {
    elements.captureDetail.textContent = "On — no confirmed port";
  } else if (!connected) {
    elements.captureDetail.textContent = `On — 127.0.0.1:${port}, unconfirmed`;
  } else if (state.proxyListening === false) {
    elements.captureDetail.textContent = `On — nothing answering on 127.0.0.1:${port}`;
  } else {
    elements.captureDetail.textContent = `On — 127.0.0.1:${port}`;
  }

  // Starting the app and reloading the extension both happen outside this panel, so
  // re-reading the bridge has to be one click rather than closing and reopening the popup.
  elements.retry.hidden = connected;
}

function render(status) {
  if (!status || status.error) {
    showError(status?.error ?? "The extension could not read its own state.");
    elements.appState.textContent = "Unavailable";
    return;
  }

  renderFacts(status);

  if (status.workerFailure) {
    // The background page is gone, so nothing can be written. Say so, disable the controls
    // that would silently do nothing, and keep the facts read from here.
    elements.appState.textContent = "Background not running";
    elements.appState.classList.remove("ok");
    elements.capture.disabled = true;
    elements.port.disabled = true;

    const detail = status.workerFailure.initFailure
      ? ` The background reported: ${status.workerFailure.initFailure}`
      : "";
    showError(
      `${status.workerFailure.reason}${detail} ` +
        "Open about:addons, find ProxyMaxx, and press Reload. If an Errors button appears next to it, open that and copy the message."
    );
  } else {
    elements.capture.disabled = false;
    elements.port.disabled = false;
    elements.error.hidden = true;
    elements.error.title = "";
  }

  // A refused enable is a message about the action, not a broken extension, so it goes in
  // the error line without taking the panel down.
  if (status.enableError) {
    showError(status.enableError);
  }

  if (status.lastProxyError) {
    const error = status.lastProxyError;
    const when = new Date(error.at);
    showError(`Proxy error at ${when.toLocaleTimeString()}: ${error.error}${error.details ? ` — ${error.details}` : ""}`);
    elements.error.title = "Click to dismiss";
  }

  renderChecks(buildChecks(status));
}

// MARK: - Talking to the background page

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
    const stored = await withTimeout(browser.storage.local.get({ [key]: fallback }), 800, "browser.storage");
    return stored[key];
  } catch {
    return fallback;
  }
}

async function degradedStatus(reason) {
  return {
    port: await readStored("port", null),
    effectivePort: null,
    portSource: "none",
    weOwnProxy: await readStored("weOwnProxy", false),
    lastProxyError: await readStored("lastProxyError", null),
    proxyType: "unknown",
    app: { connected: false, reason: "The background page is not running, so the app cannot be asked." },
    workerFailure: { reason, initFailure: await readStored("initFailure", null) },
  };
}

const PAGE_TIMEOUT_LABEL = "The background page";

async function send(command, extra = {}, attempt = 1) {
  // The first attempt waits like a person would; the retry is short, because a page that
  // is merely not registered yet fails fast. Two long waits would leave the panel staring
  // at "Checking…" for five seconds before it admits anything is wrong.
  const timeout = attempt === 1 ? 1800 : 800;

  let status;
  try {
    status = await withTimeout(browser.runtime.sendMessage({ cmd: command, ...extra }), timeout, PAGE_TIMEOUT_LABEL);
  } catch (error) {
    const reason = String(error?.message ?? error);
    if (attempt === 1) {
      // Covers the first message racing the page's registration, and the page being
      // torn down mid-request.
      await new Promise((resolve) => setTimeout(resolve, 300));
      return send(command, extra, 2);
    }
    render(await degradedStatus(reason));
    return;
  }

  if (status === undefined) {
    render(await degradedStatus("The background page answered with nothing."));
    return;
  }

  render(status);
}

// MARK: - Wiring

// Always visible, before anything can fail: if this number is not the version you just
// built, the browser is still running the previous files and no other result means anything.
try {
  elements.version.textContent = `v${browser.runtime.getManifest().version}`;
} catch {
  // Leave it blank rather than blocking the panel.
}

elements.capture.addEventListener("click", () => {
  send(elements.capture.getAttribute("aria-pressed") === "true" ? "disable" : "enable");
});

elements.port.addEventListener("change", () => {
  send("setPort", { value: elements.port.value });
});

elements.retry.addEventListener("click", () => {
  send("status");
});

elements.error.addEventListener("click", () => {
  send("clearError");
});

// Everything above is synchronous, so reaching this line means the script ran to the end.
// Anything that failed before it left the placeholder text on screen instead of silence.
if (bootWarning) bootWarning.hidden = true;

send("status");
