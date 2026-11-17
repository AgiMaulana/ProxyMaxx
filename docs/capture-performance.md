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
