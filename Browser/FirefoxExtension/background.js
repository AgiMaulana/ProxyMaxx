// Request routing leaves Firefox's browser-wide proxy settings alone.
const HOST_NAME = "com.proxymaxx.browser";
const SITE_PERMISSION = { origins: ["<all_urls>"] };
const PASSTHROUGH = [];
const DEFAULTS = {
  port: null,
  knownPort: null,
  captureEnabled: false,
  lastProxyError: null,
};
const NO_PORT_MESSAGE =
  "Nothing has reported a capture port yet. Start ProxyMaxx or `proxymaxx-cli serve`, then try again, or enter a port below.";
const SITE_ACCESS_MESSAGE =
  "Allow ProxyMaxx access to websites to route their requests through the capture proxy.";

let settings = { ...DEFAULTS };
let app = { connected: false, reason: "The app has not been queried." };
let resolved = { port: null, source: "none" };
let siteAccess = false;
let privateBrowsingAllowed = false;
let permissionRevision = 0;
let requestListenerRegistered = false;
let listenerError = null;
let migrationError = null;
let activePort = null;
let route = PASSTHROUGH;
let initialized = false;
let commandQueue;

function describe(value) {
  return String(value?.message ?? value);
}

async function recordFailure(error) {
  settings.lastProxyError = { at: Date.now(), error: describe(error) };
  try {
    await browser.storage.local.set({ lastProxyError: settings.lastProxyError });
  } catch (storageError) {
    console.error("Could not save the Firefox capture error:", storageError);
  }
}

function updateRoute() {
  const port = settings.captureEnabled && siteAccess && requestListenerRegistered && !migrationError ? resolved.port : null;
  if (activePort === port) return;
  activePort = port;
  // An empty array preserves the existing proxy chain. Terminal null prevents
  // active capture from falling back to that chain when ProxyMaxx is unreachable.
  route = port === null ? PASSTHROUGH : [{ type: "http", host: "127.0.0.1", port }, null];
}

function routeRequest() {
  // Only a cold background waits for hydration; requests never query storage or the app.
  return initialized ? route : initialization.then(() => route);
}

function registerRequestListener() {
  if (requestListenerRegistered) return;
  try {
    browser.proxy.onRequest.addListener(routeRequest, { urls: ["<all_urls>"] });
    requestListenerRegistered = true;
    listenerError = null;
  } catch (error) {
    listenerError = `Firefox request routing could not start: ${describe(error)}`;
  }
}

async function saveSettings(changes) {
  await browser.storage.local.set(changes);
  Object.assign(settings, changes);
  updateRoute();
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

function validPort(port) {
  return Number.isInteger(port) && port >= 1 && port <= 65535;
}

// Use the app's live port, then its remembered port, then the manual fallback.
function resolvePort() {
  const reported = app.connected ? app.state?.httpPort : null;
  if (validPort(reported)) return { port: reported, source: "app" };
  if (validPort(settings.knownPort)) return { port: settings.knownPort, source: "last" };
  if (validPort(settings.port)) return { port: settings.port, source: "manual" };
  return { port: null, source: "none" };
}

async function refresh() {
  app = await askApp();
  const nextPort = resolvePort();
  if (nextPort.source === "app" && settings.knownPort !== nextPort.port) {
    await saveSettings({ knownPort: nextPort.port });
  }
  resolved = nextPort;
  privateBrowsingAllowed = await browser.extension.isAllowedIncognitoAccess();
  const revision = permissionRevision;
  const allowed = await browser.permissions.contains(SITE_PERMISSION);
  if (revision === permissionRevision) siteAccess = allowed;
  registerRequestListener();
  updateRoute();
  if (migrationError || listenerError) await recordFailure(migrationError ?? listenerError);
}

async function initialize() {
  const stored = await browser.storage.local.get({
    ...DEFAULTS,
    captureEnabled: null,
    weOwnProxy: false,
    requestRoutingMigrated: false,
  });
  settings = {
    port: stored.port,
    knownPort: stored.knownPort,
    captureEnabled: typeof stored.captureEnabled === "boolean" ? stored.captureEnabled : stored.weOwnProxy === true,
    lastProxyError: stored.lastProxyError,
  };
  if (typeof stored.captureEnabled !== "boolean") {
    await saveSettings({ captureEnabled: settings.captureEnabled });
  }

  if (!stored.requestRoutingMigrated) {
    try {
      const legacy = await browser.proxy.settings.get({});
      if (legacy.levelOfControl === "controlled_by_this_extension") {
        const cleared = await browser.proxy.settings.clear({});
        if (cleared === false) throw new Error("Firefox did not clear the previous ProxyMaxx proxy setting.");
      }
      await browser.storage.local.set({ requestRoutingMigrated: true });
    } catch (error) {
      // Leave migration pending so a later background start can finish it.
      migrationError = `Could not remove the previous Firefox proxy setting; request routing is blocked: ${describe(error)}`;
      await recordFailure(migrationError);
    }
  }
  await browser.storage.local.remove(["weOwnProxy", "captureLocalhost", "initFailure"]);
  await refresh();
}

function report(extra = {}) {
  return {
    captureEnabled: settings.captureEnabled,
    routingActive: activePort !== null,
    activePort,
    siteAccess,
    privateBrowsingAllowed,
    port: settings.port,
    effectivePort: resolved.port,
    portSource: resolved.source,
    lastProxyError: settings.lastProxyError,
    app,
    ...extra,
  };
}

async function handle(command, message) {
  switch (command) {
    case "status":
      await refresh();
      return report();
    case "enable": {
      await refresh();
      const enableError = migrationError ?? (!siteAccess ? SITE_ACCESS_MESSAGE : listenerError ?? (resolved.port === null ? NO_PORT_MESSAGE : null));
      if (enableError) {
        await recordFailure(enableError);
        return report({ enableError });
      }
      await saveSettings({ captureEnabled: true });
      return report({ enableError: null });
    }
    case "disable":
      await saveSettings({ captureEnabled: false });
      await refresh();
      return report();
    case "setPort": {
      const typed = String(message.value ?? "").trim();
      const port = typed === "" ? null : Number(typed);
      if (port !== null && !validPort(port)) return { error: "The port must be between 1 and 65535." };
      await saveSettings({ port });
      await refresh();
      return report();
    }
    case "clearError":
      await saveSettings({ lastProxyError: null });
      await refresh();
      return report();
    case "ping":
      return { ok: true, pong: true, version: browser.runtime.getManifest().version };
    default:
      return { error: `Unknown command: ${command}` };
  }
}

function permissionsChanged(permissions, removed) {
  if (!permissions.origins?.length) return;
  permissionRevision += 1;
  if (removed) {
    siteAccess = false;
    updateRoute();
  }
  commandQueue = commandQueue.then(refresh).catch(recordFailure);
}

// Register wakeup hooks synchronously, before storage or native messaging can yield.
browser.runtime.onMessage.addListener((message) => {
  const response = commandQueue.then(() => handle(message?.cmd, message)).catch(async (error) => {
    await recordFailure(error);
    return { error: describe(error) };
  });
  commandQueue = response;
  return response;
});
registerRequestListener();
browser.proxy.onError.addListener((error) => {
  void recordFailure(error);
});
browser.permissions.onAdded.addListener((permissions) => permissionsChanged(permissions, false));
browser.permissions.onRemoved.addListener((permissions) => permissionsChanged(permissions, true));
browser.runtime.onStartup.addListener(() => initialization);
browser.runtime.onInstalled.addListener(() => initialization);

const initialization = initialize().catch(recordFailure).finally(() => {
  initialized = true;
});
commandQueue = initialization;
