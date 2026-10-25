// Routing is background listener state, not proof of network capture.
// If the background is unavailable, keep the readable facts and disable writes.

const bootWarning = document.getElementById("boot");

// Replace placeholder HTML with the script failure.
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
  routing: document.getElementById("fact-routing"),
  siteAccess: document.getElementById("fact-site-access"),
  scope: document.getElementById("fact-scope"),
  privateHelp: document.getElementById("private-help"),
  app: document.getElementById("fact-app"),
  ca: document.getElementById("fact-ca"),
  port: document.getElementById("opt-port"),
  error: document.getElementById("error"),
  errorMessage: document.getElementById("error-message"),
  dismissError: document.getElementById("dismiss-error"),
  retry: document.getElementById("retry"),
  checks: document.getElementById("checks"),
};

let currentStatus = null;
let capturePending = false;

function check(verdict, state, text) {
  return { verdict, state, text };
}

const BRIDGE_FIX =
  "Open ProxyMaxx and press Install Browser Extension…, then use Check again. For a temporary add-on, press Reload in about:debugging#/runtime/this-firefox; for an installed add-on, restart Firefox.";

function buildChecks(status) {
  const { captureEnabled, routingActive, activePort, siteAccess, app } = status;
  const connected = app.connected;
  const state = connected ? app.state : null;
  const checks = [];

  if (status.workerFailure) {
    checks.push(check("Unknown", "warn", "The background is unavailable, so request routing cannot be confirmed."));
  } else if (routingActive) {
    checks.push(check("Configured", "ok", `The request listener selects 127.0.0.1:${activePort} for HTTP and HTTPS. This does not confirm that requests reach the app.`));
  } else if (captureEnabled) {
    checks.push(check("Waiting", "warn", "Capture is requested, but request routing is not configured."));
  } else {
    checks.push(check("Off", "muted", "ProxyMaxx is not selecting request routes. Firefox's existing proxy settings may still apply."));
  }

  if (siteAccess !== true) {
    checks.push(check("Site access", "warn", "Capture needs access to all websites. Turn capture on and allow Firefox's website-access request."));
  }

  if (routingActive && !connected) {
    checks.push(check("Unverified", "warn", `Routing is configured for ${activePort}, but the app is not answering to confirm a listener. If pages fail to load, turn capture off.`));
  } else if (routingActive && connected && activePort !== state.httpPort) {
    checks.push(check("Port differs", "warn", `Routing selects ${activePort}, but the app reports ${state.httpPort}. Use Check again to refresh the route.`));
  } else if (routingActive && connected && state.proxyListening === false) {
    checks.push(check("No listener", "warn", `The app reports that nothing accepts connections on 127.0.0.1:${state.httpPort}. Proxied requests will fail.`));
  } else if (routingActive && connected && state.proxyListening === true) {
    checks.push(check("Listening", "ok", `The app reports a listener on 127.0.0.1:${state.httpPort}.`));
  }

  if (connected && status.port !== null && status.effectivePort !== status.port) {
    checks.push(check("App's port", "muted", `The app reports ${state.httpPort}, which takes priority over the fallback port field.`));
  }
  if (status.portSource === "last") {
    checks.push(check("Remembered", "muted", `The selected port is ${status.effectivePort}, the port the app last reported. It takes priority over the manual fallback.`));
  }
  if (status.effectivePort === null && !status.workerFailure) {
    checks.push(check("No port", "warn", `Connect the app or enter its HTTP port as a fallback. ${BRIDGE_FIX}`));
  }

  if (!connected) {
    checks.push(check("Bridge", "warn", `The app is not answering: ${app.reason} ${BRIDGE_FIX}`));
  } else if (state.caTrusted) {
    checks.push(check("App CA", "ok", "The app reports its root CA as trusted. Firefox must also trust that CA; import it into Firefox's Authorities if HTTPS certificate errors remain."));
  } else {
    checks.push(check("Missing CA", "warn", "Install and trust the root CA in the app and in Firefox. Without trust, intercepted HTTPS requests fail certificate validation."));
  }

  checks.push(check("When off", "muted", "Turning capture off removes this extension's request routing. Firefox, system, or other extension proxy settings may still route traffic to a proxy."));
  checks.push(check("Reload tabs", "muted", "Reload tabs after changing capture. Existing connections may keep their previous route."));
  checks.push(check("Pinned TLS", "muted", "Certificate pinning can prevent HTTPS decryption even when the root CA is trusted."));
  return checks;
}

function showError(text, dismissible = false) {
  elements.error.hidden = false;
  elements.errorMessage.textContent = text;
  elements.dismissError.hidden = !dismissible;
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
  const port = status.activePort;

  elements.appState.textContent = connected ? "App connected" : "App not answering";
  elements.appState.classList.toggle("ok", connected);

  elements.routing.textContent = status.workerFailure
    ? "unknown"
    : status.routingActive ? `configured on ${port}` : "not configured";
  elements.siteAccess.textContent = status.siteAccess ? "all websites allowed" : "permission needed";
  elements.scope.textContent = status.privateBrowsingAllowed === true
    ? "normal and private windows"
    : status.privateBrowsingAllowed === false ? "normal windows" : "private access unknown";
  elements.privateHelp.hidden = status.privateBrowsingAllowed === true;
  elements.app.textContent = !connected
    ? "not reachable"
    : state.proxyListening === false
      ? `nothing accepting connections on ${state.httpPort}`
      : state.proxyListening === true
        ? `listening on ${state.httpPort}${state.socksPort ? `, SOCKS5 ${state.socksPort}` : ""}`
        : `port ${state.httpPort}; listener unconfirmed`;
  elements.ca.textContent = connected ? (state.caTrusted ? "app CA trusted; Firefox trust required" : "root CA not trusted") : "unknown";

  elements.port.value = status.port === null ? "" : String(status.port);

  elements.capture.setAttribute("aria-pressed", String(status.captureEnabled));
  elements.capture.dataset.command = status.captureEnabled ? "disable" : "enable";

  if (status.workerFailure) {
    elements.captureDetail.textContent = status.captureEnabled
      ? "Capture requested; routing unknown"
      : "Routing unknown; background unavailable";
  } else if (!status.captureEnabled) {
    elements.captureDetail.textContent = status.siteAccess
      ? "Off: click to configure request routing"
      : "Off: click to allow website access and capture";
  } else if (!status.routingActive) {
    elements.captureDetail.textContent = status.siteAccess
      ? "Requested; routing not configured. Click to turn off"
      : "Requested; website access needed. Click to turn off";
  } else if (!connected) {
    elements.captureDetail.textContent = `On: route to ${port}; app unconfirmed`;
  } else if (port !== state.httpPort) {
    elements.captureDetail.textContent = `On: route to ${port}; app reports ${state.httpPort}`;
  } else if (state.proxyListening === false) {
    elements.captureDetail.textContent = `On: no listener on ${port}`;
  } else {
    elements.captureDetail.textContent = `On: route to 127.0.0.1:${port}`;
  }

  elements.retry.hidden = connected && !status.workerFailure &&
    (!status.captureEnabled || (status.routingActive && port === state.httpPort && state.proxyListening === true));
}

function render(status) {
  if (!status || status.error) {
    showError(status?.error ?? "The extension could not read its own state.");
    elements.appState.textContent = "Unavailable";
    elements.retry.hidden = false;
    return;
  }

  currentStatus = status;
  renderFacts(status);

  if (status.workerFailure) {
    // The background is unavailable; only reads are safe here.
    elements.appState.textContent = "Background not running";
    elements.appState.classList.remove("ok");
    elements.capture.disabled = true;
    elements.port.disabled = true;

    const detail = status.workerFailure.initFailure
      ? ` The background reported: ${status.workerFailure.initFailure}`
      : "";
    showError(
      `${status.workerFailure.reason}${detail} ` +
        "For a temporary add-on, open about:debugging#/runtime/this-firefox and press Reload under ProxyMaxx. Press Inspect there to read its console errors. For an installed add-on, restart Firefox."
    );
  } else {
    elements.capture.disabled = capturePending;
    elements.port.disabled = false;
    elements.error.hidden = true;
    elements.dismissError.hidden = true;
    if (status.enableError) {
      showError(status.enableError);
    } else if (status.lastProxyError) {
      const error = status.lastProxyError;
      const when = new Date(error.at);
      showError(`Proxy error at ${when.toLocaleTimeString()}: ${error.error}`, true);
    }
  }

  renderChecks(buildChecks(status));
}

// MARK: - Talking to the background page

// Bound messaging so an unavailable background cannot leave "Checking…" forever.
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
  let siteAccess = false;
  let privateBrowsingAllowed = null;
  try {
    siteAccess = await withTimeout(browser.permissions.contains({ origins: ["<all_urls>"] }), 800, "Website access");
  } catch {
    // An unavailable permission check cannot establish access.
  }
  try {
    privateBrowsingAllowed = await withTimeout(browser.extension.isAllowedIncognitoAccess(), 800, "Private-window access");
  } catch {
    // Unknown private access is distinct from a denied permission.
  }
  return {
    captureEnabled: await readStored("captureEnabled", false),
    routingActive: false,
    activePort: null,
    siteAccess,
    privateBrowsingAllowed,
    port: await readStored("port", null),
    effectivePort: null,
    portSource: "none",
    lastProxyError: await readStored("lastProxyError", null),
    app: { connected: false, reason: "The background page is not running, so the app cannot be asked." },
    workerFailure: { reason, initFailure: await readStored("initFailure", null) },
  };
}

const PAGE_TIMEOUT_LABEL = "The background page";

async function send(command, extra = {}, attempt = 1) {
  // Preserve the short second attempt for background registration races.
  const timeout = attempt === 1 ? 1800 : 800;

  let status;
  try {
    status = await withTimeout(browser.runtime.sendMessage({ cmd: command, ...extra }), timeout, PAGE_TIMEOUT_LABEL);
  } catch (error) {
    const reason = String(error?.message ?? error);
    if (attempt === 1) {
      // The background may be registering or unloading.
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

// Show the loaded version even if later messaging fails.
try {
  elements.version.textContent = `v${browser.runtime.getManifest().version}`;
} catch {
  // Keep the static version if the runtime API is unavailable.
}

elements.capture.addEventListener("click", async () => {
  if (!currentStatus || capturePending) return;
  const command = currentStatus.captureEnabled ? "disable" : "enable";
  capturePending = true;
  elements.capture.disabled = true;
  try {
    if (command === "enable" && !currentStatus.siteAccess) {
      // Call before any await so Firefox retains the capture click's user gesture.
      const granted = await browser.permissions.request({ origins: ["<all_urls>"] });
      if (!granted) {
        showError("Website access was not granted. Capture remains off. Click Capture this browser to try again.");
        return;
      }
    }
    await send(command);
  } catch (error) {
    showError(String(error?.message ?? error));
  } finally {
    capturePending = false;
    elements.capture.disabled = !currentStatus || Boolean(currentStatus.workerFailure);
  }
});

elements.port.addEventListener("change", () => {
  send("setPort", { value: elements.port.value });
});

elements.retry.addEventListener("click", () => {
  send("status");
});

elements.dismissError.addEventListener("click", () => {
  send("clearError");
});

// Reaching the end means the synchronous setup completed.
if (bootWarning) bootWarning.hidden = true;

send("status");
