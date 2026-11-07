# Privacy and diagnostics

ProxyMaxx is a debugging proxy: the traffic it handles is exactly the data its users are
trying to inspect. Remote error reporting therefore has to be narrow, explicit, and off by
default.

## Why Sentry is used

Sentry tells the maintainers that an unexpected failure happened: a crash, a failed proxy
start, a certificate operation that threw, or a Map Local write that could not complete. It
does **not** replace local diagnostics. The detailed record stays in
`~/Library/Application Support/ProxyMaxx/Logs/0.log` through `10.log`, written by `LogKit`.

A useful shorthand:

> **Sentry tells us that something went wrong. LogKit helps users and developers understand
> why it went wrong.**

## Consent

Error reporting is **off by default**.

Before consent, ProxyMaxx does not:

- initialize the Sentry SDK;
- install crash handlers;
- send events, sessions, or user identifiers;
- queue events for later transmission;
- collect telemetry in the background.

Local logging continues normally. The first launch that can report offers the choice as a
balloon in the bottom-right corner of the main window, with the same explanation as the
Settings pane:

- **Turn On Error Reporting** consents immediately and switches the setting on;
- **Not Now** leaves reporting off and asks again on the next launch;
- **Don't Ask Again** leaves reporting off and stops the balloon for good;
- closing the balloon is the same as **Not Now**.

Once the question is answered, the balloon does not return. Reporting can be turned on later
under **Settings → Privacy & Diagnostics** by turning on **Error reporting**; turning it off
again stops new events. The choice is stored in `UserDefaults` under
`ProxyMaxxErrorReportingEnabled`, and the "don't ask again" answer under
`ProxyMaxxErrorReportingAsked`. Enabling reporting in Settings counts as answering, so a
later launch never asks again.

Disabling stops new reports immediately and closes the SDK, which flushes what the SDK
permits. It cannot recall events that were already transmitted. Previously sent events are
subject to Sentry's retention policy.

## What is collected

Only information needed to diagnose an application failure:

- application version and build number;
- macOS version and architecture;
- Sentry SDK version;
- exception type and a redacted error message;
- a stack trace with source context and local variables removed;
- component and operation names;
- non-sensitive error codes;
- a random correlation ID;
- release and environment names (`development` or `production`).

Event metadata is filtered through an allowlist. Tags such as `component`, `operation`,
`error_code` and `correlation_id` survive; arbitrary application metadata does not.

## What is never sent

- HTTP request or response bodies;
- HTTP headers, including authorization headers;
- cookies and session identifiers;
- API keys, access tokens, and passwords;
- full request URLs or query parameters;
- captured HTTP traffic;
- TLS certificates or private keys;
- proxy authentication credentials;
- local file contents;
- full filesystem paths containing usernames;
- environment variables;
- user email addresses or other personal identifiers;
- raw `LogKit` log files or rotated log files.

`EventSanitizer` applies these rules in one place before any event reaches the SDK. It also
removes automatically collected request data, breadcrumbs, user information, arbitrary
context, and attachments. If a redacted event still looks like it contains a secret, the
event is dropped rather than sent.

## What is automatically collected by the SDK

Almost nothing. The Sentry integration is configured with:

- automatic session tracking off;
- automatic breadcrumb tracking off;
- network breadcrumbs off;
- swizzling off;
- performance tracing off;
- failed-request capture off;
- app-hang and watchdog tracking off;
- MetricKit off;
- memory introspection off;
- `sendDefaultPii` off.

The crash handler is the only integration kept, and it is installed by `SentrySDK.start`,
which only runs after consent. Crash reports can be delivered on the next launch; a fatal
native crash is not guaranteed to appear immediately.

## Where data goes and how long it is kept

Events go to the Sentry project identified by the DSN embedded in release builds. The DSN is
a public client identifier, not an authentication secret. The current project uses Sentry's
US ingestion endpoint (`ingest.us.sentry.io`).

There are two Sentry environments inside that project:

| Environment | Used by |
|---|---|
| `development` | Debug builds, `Scripts/run.sh`, local test runs |
| `production` | Bundles built by `.github/workflows/release.yml` |

Every event carries its environment, so a failure a developer hits while testing never looks
like one that reached a released app. The DSN is the same for both; only the tag differs.
`PROXYMAXX_SENTRY_ENVIRONMENT` can override it for a local run, but release bundles force
`production`.

Sentry's own retention settings apply. On sentry.io the default error-event retention is 90
days unless the project is configured to keep events for less time. Consult the Sentry
project settings and Sentry's privacy policy for the authoritative retention period and the
list of subprocessors.

## Local logs versus remote reporting

| | `LogKit` | Sentry reporting |
|---|---|---|
| Where | Local disk | Sentry |
| Enabled | Always | Only after explicit consent |
| Detail | Full local diagnostics | Small, sanitized event |
| Attachments | Rotated log files | None |
| Disabling it | Not applicable | Stops future reports |

Local log rotation is independent: turning Sentry off never affects `LogKit`, and turning
`LogKit` off never enables Sentry.

## GitHub issue reporting

**ProxyMaxx → Report Issue** builds a prefilled GitHub issue from recent local logs. It is a
separate, user-initiated workflow. Log lines are redacted for common secret patterns before
they enter the page, and the body warns that local logs can still contain sensitive
information. Opening the page does not submit the issue; the user reviews and edits it in
the browser. Sentry never reuses this pipeline automatically.

Because a prefilled issue places log text in a browser URL and browser history, review the
text before submitting. If a log line looks sensitive, remove it from the issue body.

## Configuration for contributors

Release builds receive the DSN from the `SENTRY_DSN` GitHub Actions secret. `bundle-app.sh`
writes a launcher that exports `SENTRY_DSN`, the variable the SDK reads, plus the environment
for the build (`production` for release bundles, `development` otherwise). Local builds have
no DSN and therefore cannot report errors; to exercise the path locally, export
`PROXYMAXX_SENTRY_DSN` (and optionally `PROXYMAXX_SENTRY_ENVIRONMENT`) before running
`Scripts/run.sh`. Verify event contents in the `development` environment, not in
`production`.

Symbolication is a separate secret: `SENTRY_AUTH_TOKEN` lets the release workflow upload the
build's `dSYM`s to the same project, so a crash in a shipped build resolves to function names
and line numbers. `bundle-app.sh` compiles release builds with `-g` for this reason and fails
one that produced no dSYMs. The token is scoped to debug-information upload, is used only by
that workflow step, and is never embedded in the app or the DMG. A release built without it
still works; its crashes simply arrive unsymbolicated.
