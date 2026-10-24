// ProxyMaxx — Firefox companion, background page.
//
// The extension owns exactly one thing the Mac app cannot reach: this browser's own
// proxy setting. It points the browser at the local proxy, reports whether the proxy
// setting is ours to change, and reads live state from the app over native messaging.
//
// It never sees request bodies. Decryption happens in the proxy, not here.
//
// Registration order matters. If this script throws while evaluating, the page never
// registers and the popup gets "Receiving end does not exist" — a blank panel with no
// explanation. So the message channel is registered first, and everything else is
// guarded and reports its own failure where the popup can read it.

const HOST_NAME = "com.proxymaxx.browser";

const DEFAULTS = {
  // The port field, unset until someone types one. It is a fallback for when nothing can be
  // asked, and it is deliberately not seeded with a number: pointing a browser at a port
  // nobody confirmed takes every page in that browser down, which is the failure this
  // ordering exists to prevent.
  port: null,
  // The last port an engine reported. Kept so a bridge that goes quiet still resolves to
  // the port that was working, instead of a default that may have moved out from under it.
  knownPort: null,
  captureLocalhost: false,
  weOwnProxy: false,
  lastProxyError: null,
};

/// The refusal when capture is asked for before anything has named a port to capture on.
const NO_PORT_MESSAGE =
  "Nothing has reported a port to capture on yet. Start ProxyMaxx or `proxymaxx-cli serve`, then try again — or enter the port in the field below.";

function describe(value) {
  return String(value?.message ?? value);
}

// MARK: - Settings

function getSettings() {
  return browser.storage.local.get(DEFAULTS);
}

/// Firefox's proxy value has no loopback-bypass exception of its own: it either proxies
/// everything or nothing, so "capture localhost" is carried by proxying at all — there is
/// no separate <-loopback> entry to opt in with like Chromium. The checkbox stays in the
/// panel so the state is legible, but either setting routes loopback here.
function proxyConfig(port) {
  return {
    proxyType: "manual",
    http: `PROXY 127.0.0.1:${port}`,
    https: `PROXY 127.0.0.1:${port}`,
    socks: `SOCKS 127.0.0.1:${port}`,
    socksVersion: 5,
  };
}

function writeProxyConfig(value) {
  return browser.proxy.settings.set({ value });
}

function readProxySetting() {
  return browser.proxy.settings.get({});
}

// MARK: - The app bridge

// One question, one answer, then disconnect. Native ports outlive background pages badly,
// and the state is cheap to re-read.
function askApp(timeoutMilliseconds = 1500) {
  return new Promise((resolve) => {
    let port;
    try {
      port = browser.runtime.connectNative(HOST_NAME);
    } catch (error) {
      resolve({ connected: false, reason: describe(error) });
      return;
    }

    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      try {
        port.disconnect();
      } catch {
        // Already gone; nothing to do.
      }
      resolve(value);
    };

    const timer = setTimeout(() => finish({ connected: false, reason: "The app did not answer." }), timeoutMilliseconds);

    port.onMessage.addListener((state) => {
      clearTimeout(timer);
      finish({ connected: true, state });
    });

    port.onDisconnect.addListener(() => {
      clearTimeout(timer);
      const failure = browser.runtime.lastError ?? port.error;
      // Not installed yet is the normal state before the app writes its manifests, so
      // it is reported as a plain reason rather than an error.
      finish({ connected: false, reason: failure?.message ?? "The browser bridge is not installed." });
    });

    try {
      port.postMessage({ type: "hello" });
    } catch (error) {
      clearTimeout(timer);
      finish({ connected: false, reason: describe(error) });
    }
  });
}

// MARK: - Commands

/// The port the browser should be pointed at, and where that number came from.
///
/// The app or the CLI reports where it actually listens, because a busy 9090 makes the
/// engine re-select a port; that number is remembered so it survives the bridge going
/// quiet. `port: null` means nothing has ever named one, which is a state to report rather
/// than a number to invent.
function resolvePort(app, settings) {
  const reported = app.connected ? app.state?.httpPort : null;
  if (Number.isInteger(reported) && reported > 0) return { port: reported, source: "app" };
  if (Number.isInteger(settings.knownPort) && settings.knownPort > 0) {
    return { port: settings.knownPort, source: "last" };
  }
  if (Number.isInteger(settings.port) && settings.port > 0) {
    return { port: settings.port, source: "manual" };
  }
  return { port: null, source: "none" };
}

/// Ask the app once, and remember the port it names.
async function resolveLivePort() {
  const settings = await getSettings();
  const app = await askApp();
  const resolved = resolvePort(app, settings);
  if (resolved.source === "app") {
    await browser.storage.local.set({ knownPort: resolved.port });
  }
  return resolved;
}

async function applyIfOurs() {
  const settings = await getSettings();
  if (!settings.weOwnProxy) return;
  const { port } = await resolveLivePort();
  // Nothing confirmed: leaving the browser on its own settings is the only safe move.
  if (port === null) return;
  await writeProxyConfig(proxyConfig(port));
}

/// Turn capture on, or say why it cannot be.
///
/// Firefox shares one browser-global proxy setting with no restoration snapshot, so unlike
/// Chromium there is no level-of-control to lose: our value is the value.
async function enable() {
  const settings = await getSettings();
  const { port } = await resolveLivePort();
  if (port === null) return NO_PORT_MESSAGE;
  await writeProxyConfig(proxyConfig(port));
  await browser.storage.local.set({ weOwnProxy: true, lastProxyError: null });
  return null;
}

async function disable() {
  await writeProxyConfig({ proxyType: "none" });
  await browser.storage.local.set({ weOwnProxy: false });
}

function buildReport(settings, setting, app, resolved, extra) {
  return {
    port: settings.port,
    // What the browser should be pointed at, and which of the three places that number came
    // from. Both are distinct from the port field, because an engine can move its port out
    // from under the field.
    effectivePort: resolved.port,
    portSource: resolved.source,
    captureLocalhost: settings.captureLocalhost,
    weOwnProxy: settings.weOwnProxy,
    lastProxyError: settings.lastProxyError,
    proxyType: setting?.value?.proxyType ?? "unknown",
    app,
    ...extra,
  };
}

async function report(extra = {}) {
  const settings = await getSettings();
  let setting = null;
  try {
    setting = await readProxySetting();
  } catch {
    // Leave setting null; the report names "unknown" rather than failing wholesale.
  }
  const app = await askApp();
  const resolved = resolvePort(app, settings);
  if (resolved.source === "app") {
    await browser.storage.local.set({ knownPort: resolved.port });
  }

  // Self-heal a stale port. The app re-selects when its preferred port is busy, and a
  // browser left pointing at the old one captures nothing while looking perfectly
  // configured. Cheaper to correct here than to expect someone to notice the difference.
  const appliedPort = extractAppliedPort(setting);
  const stalePort = Number.isInteger(appliedPort) && resolved.port !== null && appliedPort !== resolved.port;
  if (settings.weOwnProxy && resolved.port !== null && stalePort) {
    try {
      await writeProxyConfig(proxyConfig(resolved.port));
      setting = await readProxySetting();
    } catch {
      // Fall through: the report still names the port we could not apply.
    }
  }

  return buildReport(settings, setting, app, resolved, extra);
}

/// The port currently applied in the browser, pulled back out of the setting
/// `browser.proxy.settings.get` gave us. Firefox hands back PAC-style strings
/// (`"PROXY 127.0.0.1:9090"`, sometimes the comma form after a reload), so take the last
/// number that looks like a port and tolerate both spellings.
function extractAppliedPort(setting) {
  const value = setting?.value?.https;
  if (typeof value !== "string") return null;
  const match = value.match(/:(\d+)\D*$/) || value.match(/,(\d+)\D*$/);
  const port = match ? parseInt(match[1], 10) : NaN;
  return Number.isInteger(port) && port > 0 ? port : null;
}

async function handle(command, message) {
  switch (command) {
    case "status":
      return report();
    case "enable":
      // A refusal is a message about the action, so it rides along with a normal report
      // instead of replacing it: the panel stays readable and capture simply stays off.
      return report({ enableError: await enable() });
    case "disable":
      await disable();
      return report();
    case "setLocalhost":
      await browser.storage.local.set({ captureLocalhost: Boolean(message.value) });
      await applyIfOurs();
      return report();
    case "setPort": {
      // An empty field clears the override, which is how the port goes back to whatever the
      // app reports. It is the only way to undo a wrong number.
      const typed = String(message.value ?? "").trim();
      if (typed === "") {
        await browser.storage.local.set({ port: null });
        await applyIfOurs();
        return report();
      }
      const port = Number(typed);
      if (!Number.isInteger(port) || port < 1 || port > 65535) {
        return { error: "The port must be between 1 and 65535." };
      }
      await browser.storage.local.set({ port });
      await applyIfOurs();
      return report();
    }
    case "clearError":
      await browser.storage.local.set({ lastProxyError: null });
      return report();
    case "ping":
      return { ok: true, pong: true, version: browser.runtime.getManifest().version };
    default:
      return { error: `Unknown command: ${command}` };
  }
}

// MARK: - Registration

// First, and unconditional: this is the one registration the popup cannot survive without.
browser.runtime.onMessage.addListener((message, _sender, respond) => {
  handle(message?.cmd, message).then(respond, (error) => respond({ error: describe(error) }));
  return true; // Keep the channel open for the asynchronous answer.
});

/// Everything that went wrong while registering the optional hooks, so the popup can name
/// it instead of showing a blank panel.
const initFailures = [];

function recordInitFailure(message) {
  initFailures.push(message);
  const pending = browser.storage?.local?.set?.({ initFailure: message });
  if (pending && typeof pending.catch === "function") pending.catch(() => {});
}

/// Register a background hook, or record why it could not be. An older or stripped
/// Firefox build may not expose every event; a missing optional event must never take
/// the whole page down with it.
function registerSafely(label, register) {
  try {
    register();
  } catch (error) {
    recordInitFailure(`${label}: ${describe(error)}`);
  }
}

registerSafely("proxy re-assertion", () => {
  browser.runtime.onStartup.addListener(() => {
    applyIfOurs().catch(() => {});
  });
});

registerSafely("first-install setup", () => {
  browser.runtime.onInstalled.addListener(() => {
    applyIfOurs().catch(() => {});
  });
});

// Everything optional registered. Clear a failure left by an earlier build — but never
// the one this run just recorded.
if (initFailures.length === 0) {
  const pending = browser.storage?.local?.remove?.("initFailure");
  if (pending && typeof pending.catch === "function") pending.catch(() => {});
}
