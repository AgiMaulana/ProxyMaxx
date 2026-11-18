# Capture performance baseline

Measurement for [issue #58](https://github.com/AgiMaulana/ProxyMaxx/issues/58): the app
hangs under a burst of flow snapshots, most visibly with a CCTV / MJPEG dashboard that
keeps several streaming responses open. Phase 0 adds instrumentation only; no behaviour
changed.

## What is measured

`FlowKit.CaptureMetrics` reports into the `oss.proxymaxx` subsystem, category `capture`:

| Signpost interval | Covers |
| --- | --- |
| `snapshot.enqueue` | Engine callback handing one snapshot to the main actor |
| `ingest.drain` | Reading and consuming the shared spool while attached to a CLI-owned engine |
| `ingest.upsert` | Upserting one snapshot (or a drained batch) into `FlowStore` |
| `persistence.write` | `FlowSpool.write` plus `SessionLog.append` |
| `list.derive` | Recomputing the filtered traffic list and the sidebar summary |

A `snapshot.dropped` event is emitted whenever a bounded stage refuses snapshots. Phase 0
has no bounded stage yet, so it stays at zero; later phases report into the same event.

The counters behind these intervals are snapshots enqueued, snapshots ingested, pending
snapshots, dropped snapshots, persistence writes, spool drains, list derivations, and
retained flow count.

## Backlog report

Every 5 s the app logs one line to the structured log while there is work to explain — a
pending snapshot backlog, a drop, or a spool drain from an attached engine:

```
capture: 412.0 snapshots/s in, 260.0 handled/s, 153 pending, 0 dropped, 520.0 persistence writes/s, 8124 flows
```

An idle window stays silent, and the line goes to `LogKit`, not to the activity feed, so
the report cannot add redraws of its own.

## Capturing a baseline

1. Start the app with `Scripts/run.sh`, connect the Chrome extension, and open the CCTV
   dashboard from the issue.
2. Run the capture script:

   ```sh
   Scripts/capture-perf-baseline.sh
   ```

   It writes `perf-baseline/sample-<stamp>.txt` and `perf-baseline/signposts-<stamp>.log`.
   Set `PROXYMAXX_PID` to target a specific process and `PROXYMAXX_SAMPLE_SECONDS` to
   change the 15 s window.

3. For interval timelines, record the same reproduction in Instruments:

   ```sh
   xctrace record --template 'Time Profiler' --attach "$(pgrep -x ProxyMaxx)" \
       --time-limit 15s --output perf-baseline/trace.trace
   ```

Expected hot stacks before the fix: `SessionLog.append`, `FlowSpool.write`,
`JSONEncoder`, `Data.append`, and the SwiftUI `Table` update.

## Comparing later phases

The signpost names and counter names are the stable contract. A later phase that moves
ingestion off the main actor, caps captured bodies, throttles persistence, or caches the
list derivation is accepted when the same reproduction shows the ingest, persistence, or
list interval shrink and the backlog report stops firing.

---

## Phase 7 — Acceptance and regression gates

Phase 7 defines the automated and manual gates required to verify that the capture-performance architecture ([issue #58](https://github.com/AgiMaulana/ProxyMaxx/issues/58) / [issue #66](https://github.com/AgiMaulana/ProxyMaxx/issues/66)) eliminates UI hangs without degrading traffic forwarding or losing terminal state.

### 1. Automated unit regression tests

Run the unit tests across the capture pipeline modules:

```sh
# Ingest buffer coalescing and overflow protection
swift test --filter FlowIngestBufferTests

# Body caps, streaming detection, and bounded body emits
swift test --filter FlowBodyCapTests

# Persistence throttling and immediate terminal writes
swift test --filter FlowPersistenceTests

# Batch store upsert and amortized chunk eviction
swift test --filter FlowStoreBatchEvictionTests
```

### 2. Chunked MJPEG streaming integration test

Exercises the proxy engine end-to-end against a 100 MB chunked `multipart/x-mixed-replace` stream:

```sh
swift test --filter MJPEGStreamingIntegrationTests
```

Verification assertions:
- **Client integrity:** `curl` receives all 100 MB of stream data without truncation or corruption.
- **Capture capped:** Captured body in `Flow` is strictly capped at `streamingBodyCaptureBytes` (256 KiB).
- **Metadata flags:** `isStreamingResponse == true`, `responseBodyTruncated == true`.
- **Memory bounded:** Proxy does not retain the growing 100 MB body in memory.
- **Bounded snapshots:** Interim body emissions stop once capped; final snapshot emitted on completion.

### 3. Stress test harness (500 concurrent flows for 60 s)

Run the stress harness to verify throughput, main-thread responsiveness, and snapshot integrity under heavy traffic bursts:

```sh
Scripts/capture-perf-stress.sh --concurrency 500 --duration 60 --port 9090
```

Acceptance criteria:
- **Zero final snapshot drops:** Terminal snapshots are never dropped, even when in-flight buffers coalesce or evict.
- **Main-thread responsiveness:** Main-thread stall remains `< 100 ms` during continuous traffic.
- **Throughput:** Proxy engine throughput remains sustained without backpressure deadlocks.

### 4. Manual gate: Chrome extension + CCTV multi-camera dashboard

To verify live UI interactivity with real browser streaming:

1. **Start ProxyMaxx:**
   ```sh
   Scripts/run.sh
   ```
2. **Start the Mock CCTV Multi-Camera Server:**
   ```sh
   python3 Scripts/cctv-mock-server.py --port 8088 --fps 10
   ```
3. **Open Chrome with the ProxyMaxx extension connected:**
   Navigate to `http://127.0.0.1:8088/` to load the 12-camera live CCTV grid.
4. **Interactive Verification Checklist:**
   - **Smooth Scrolling:** Scroll the traffic table and sidebar in ProxyMaxx; it should scroll smoothly at 60 fps without stutter.
   - **Immediate Selection:** Click between streaming flows; the inspector updates instantly without delay.
   - **Badges:** The streaming rows show the orange `Streaming` badge and `Truncated` badge in the inspector.
   - **Inspector Previews:** Payload previews display the truncation notice and slice preview without loading excessive data into views.
   - **Memory Flatline:** Activity Monitor shows ProxyMaxx memory usage remains flat instead of growing continuously.
   - **Backlog Silence:** Structured logs (`log stream --predicate 'subsystem == "oss.proxymaxx"'`) drain quickly and do not log persistent backlog lines.
