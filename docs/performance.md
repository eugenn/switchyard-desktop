# Statistics performance — 2026-09-15

## Changes

- `RoutingLogReader` reuses the decoded snapshot when the bounded tail bytes and
  requested record limit match. Byte comparison detects same-sized replacements,
  truncation and completed partial lines without relying on timestamp precision.
  One lock serializes concurrent reads and cache updates.
- Reads stop at the observed file size, with a hard 1 MiB cap even if the writer
  keeps appending. The reader scans backwards until enough records are decoded,
  avoiding a full-tail String and an array of every line.
- Date parsing uses reusable, Sendable ISO 8601 format styles. Alternative field
  names are indexed once per record instead of repeatedly normalizing and scanning
  all fields for each absent key.
- Metrics aggregate counts, tokens, buckets and model shares in one pass. This
  removes intermediate arrays of filtered records and timestamp tuples, plus
  separate dictionaries for each per-model counter.
- The monitor keeps three cache slots for the current summaries. Keys include
  refresh time, record revision, profile assignments and relevant selections.
  Window aging and SwiftUI observation remain active on cache hits.
- The LiteLLM login output handler removes itself on EOF to avoid repeated empty
  callbacks during the remaining startup work.

## Measurement

The opt-in `routingPerformance` test uses 500 synthetic Switchyard-shaped records
with three models and classifier calls. Each log workload runs 30 times; each
metrics/view workload runs 1,000 times. The append workload adds one record before
each read. The view workload reads the three summaries, model IDs and request
filter, without rendering SwiftUI.

Measured locally on Apple Silicon with Xcode Swift 6.3.3 in release configuration:

| Workload | Before, ms/iteration | After, ms/iteration |
| --- | ---: | ---: |
| Unchanged log, 500 records | 199.834 | 0.037 |
| Append and read, 500 records | 199.346 | 20.538 |
| Metrics aggregation | 0.575 | 0.140 |
| Statistics view data reads | 3.759 | 0.101 |

These are local wall-clock microbenchmarks, not end-to-end request latency or
whole-app CPU/RSS measurements. In particular, the unchanged-log improvement
comes from skipping decoding. A changed tail still decodes its recent records.
The reader retains one tail of at most 1 MiB plus its decoded records; caches
retain only the current summaries, rather than growing with selection history.
Temporary allocations are reduced; a whole-app RAM reduction is not claimed.

Reproduce using the Xcode toolchain (the system Command Line Tools SDK on this
machine currently fails to load `SwiftUIMacros.StateMacro`):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  SWITCHYARD_DESKTOP_BENCHMARK=1 \
  xcrun swift test -c release --filter routingPerformance
```

Normal tests skip the benchmark and use no machine-dependent timing thresholds.
Regression coverage includes file replacement/removal/recreation, limits,
partial lines, Unicode, concurrent readers, time-window boundaries, classifier
accounting, cache invalidation and SwiftUI observation after a cache hit.

Final validation: the Swift test run reported 288 tests with no failures,
including real Switchyard start/stop and unexpected-exit checks. The two fixture
export tests and opt-in benchmark were skipped by the normal run; the benchmark
and cache-observation regression also passed in release configuration. The
Switchyard snapshot manifest verification and `git diff --check` passed.
