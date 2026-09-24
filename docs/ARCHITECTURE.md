# Goose Architecture

A map of how Goose works, written for people extending it: pulling data out,
comparing it with Apple Watch / Apple Health, or building new features on top.

## The Big Picture

```text
 WHOOP 5.0 band
      │  Bluetooth LE (custom WHOOP GATT service + standard HR/Battery/DeviceInfo)
      ▼
 GooseBLEClient (Swift, CoreBluetooth)          GooseSwift/GooseBLEClient*.swift
      │  raw notification bytes + command writes
      ▼
 GooseAppModel pipelines (Swift)                GooseSwift/GooseAppModel+*.swift
      │  reassemble frames → queue → batch
      ▼
 GooseRustBridge  ── JSON over C ABI ──►  goose_core (Rust static library)
      │                                        Rust/core/src/bridge.rs  (router)
      │                                        protocol.rs  (frame parsing, CRC)
      │                                        store.rs     (SQLite schema/IO)
      │                                        metrics*.rs, *_rollup.rs (scores)
      ▼
 SQLite: Application Support/GooseSwift/goose.sqlite (on the phone)
      │
      ▼
 HealthDataStore / MoreDataStore (Swift)  ──►  SwiftUI tabs: Home · Health · Coach · More
```

Everything runs on the phone. There is no Goose server. The only network call
is the optional Coach chat, which signs in with a ChatGPT account.

## Layer 1: Bluetooth (`GooseBLEClient`)

`GooseBLEClient.swift` is one `ObservableObject`, split across extension files:

| File | Responsibility |
|---|---|
| `GooseBLEClient.swift` | State (`@Published`), UUID constants, command enums |
| `+CentralDelegate.swift` | Scan results, connect/disconnect, state restoration |
| `+PeripheralDelegate.swift` | Service/characteristic discovery, notifications |
| `+UserActions.swift` | Scan, connect, client hello, debug research commands |
| `+Commands.swift` | Central setup, reconnect logic, subscriptions, GATT setup |
| `+HistoricalCommands.swift` / `+HistoricalHandlers.swift` | Offline history download |
| `+Parsing.swift` | V5 frame builder, CRC16/CRC32, battery/HR parsing, WHOOP identity checks |
| `+VitalsAndLogging.swift` | Live HR, RR intervals → HRV (RMSSD), resting HR estimate |
| `+DebugAndSync.swift` | Sync toasts, failure sheets, debug snapshots |

**GATT layout.** WHOOP 5.0 exposes a custom service. Goose knows two UUID
families (`fd4b…` is the V5 one, `61080…` is legacy):

| UUID suffix | Role |
|---|---|
| `…0001` | WHOOP service |
| `…0002` | Command characteristic (write) |
| `…0003/4/5` | Data/event notification characteristics |
| `…0007` | Debug-menu characteristic |
| `180D/2A37` | Standard Heart Rate Measurement (live HR + RR intervals) |
| `180F/2A19`, `2BED` | Battery level / status |
| `180A/2A24…2A29` | Device information (model, firmware, …) |

**Command frame (V5).** Built by `buildV5CommandFrame` and mirrored in Rust
`protocol.rs`:

```text
aa 01 <len lo> <len hi> 00 01 <crc16-modbus of header, 2 bytes>
<packet type=command> <sequence> <command number> <data…> <zero pad to 4 bytes>
<crc32 of payload, 4 bytes little-endian>
```

Known command numbers: `34` GET_DATA_RANGE, `22` SEND_HISTORICAL_DATA,
`23` HISTORICAL_DATA_RESULT (ack), `10/11` clock set/get, `66–69` alarms.
Several more research/debug commands are defined in `debugResearchCommandDefinitions`.

**Connection lifecycle.** scan (filtered to WHOOP services) *plus*
`retrieveConnectedPeripherals` for straps that iOS already holds connected →
`connect` → discover services → subscribe to notifications → `ready` →
send client hello → optional clock sync / historical sync. The last strap is
remembered in `UserDefaults` and reconnected automatically on launch. The
central uses a restoration identifier, so iOS can relaunch Goose in the
background for BLE events (`bluetooth-central` background mode).

**Only one app can talk to the strap at a time.** The official WHOOP app and
Goose compete for the connection. Force-quit the WHOOP app while using Goose.

## Layer 2: Swift ingest pipelines (`GooseAppModel`)

`GooseAppModel` (main-actor) owns the BLE client and the Rust bridge. It wires
BLE callbacks into background queues:

- `+NotificationPipeline`: reassembles frames split across BLE packets
  (`gooseFrames(in:)`), parses them, and hands them to the capture writer.
- `CaptureFrameWriteQueue`: batches frames into `capture.import_frame_batch`
  so SQLite writes don't block the UI.
- `+HealthCapture`: timed "health packet capture" sessions for specific
  packet families (HR, temperature, respiratory, SpO2 candidates).
- `+Overnight*` + `OvernightRawNotificationSpool` + `OvernightSQLiteMirrorQueue`:
  "Overnight Guard" keeps a raw spool of every notification during sleep so
  nothing is lost, then mirrors it into SQLite.
- `+ActivityRecording` / `ActivitySessionModel` / `ActivityLocationTracker`:
  manual workouts with GPS, plus a Live Activity (`GooseWorkoutLiveActivityExtension`).
- `PassiveActivityDetector`: detects movement bouts from motion packets.
- `HeartRateSeriesStores`: live HR samples → hourly ranges for charts.

## Layer 3: Rust core (`Rust/core`)

Compiled to `libgoose_core.a` and linked into the app. Swift calls exactly
one function:

```c
char *goose_bridge_handle_json(const char *request_json); // + goose_bridge_free_string
```

Request: `{"schema":"goose.bridge.request.v1","method":"metrics.hrv_features","args":{…}}`.
Response: `{"ok":true,"result":{…},"timing":{…}}`. `bridge.rs` routes about 150
methods. The main groups the app uses are:

| Group | Examples | Purpose |
|---|---|---|
| `protocol.*` | `parse_frame_hex_batch` | Deframe, check CRC, classify packets |
| `capture.*` | `start_session`, `import_frame_batch` | Persist raw + decoded frames |
| `metrics.*` | `hrv_features`, `sleep_score_from_features`, `recovery_score_from_features`, `strain_…`, `stress_…`, `energy_daily_rollup`, `step_counter_*` | Feature extraction and scores |
| `activity.*` | `create_session`, `list_metrics` | Workouts and activity metrics |
| `sleep.*` | `import_external_history`, `validate_*_labels` | Sleep windows, labels |
| `export.*` / `privacy.lint` | `raw_timeframe` | JSONL/CSV/SQLite export bundles |
| `health_sync.*` | `dry_run` | Plan (dry run) for writing to HealthKit |
| `calibration.*`, `metrics.reference_compare` | | Compare Goose algorithms to reference libraries |

The same crate also builds ~30 desktop CLIs (`src/bin/`). For example,
`goose-capture-sqlite-import` and `goose-raw-export` work on an exported
SQLite file on your Mac. They are the easiest way to analyze band data offline.

**SQLite tables (in `store.rs`).** `raw_evidence` and `decoded_frames` hold
every captured frame. `capture_sessions`, `ble_raw_notifications` and
`historical_range_polls` hold capture bookkeeping. `activity_sessions`,
`activity_metrics`, `daily_activity_metrics` and `hourly_activity_metrics`
hold activity. `daily_recovery_metrics`, `metric_values`,
`metric_components` and `metric_provenance` hold scores. `external_sleep_*`
and `sleep_correction_labels` hold sleep. `calibration_*` and
`algorithm_*` hold algorithm state.

## Layer 4: UI (SwiftUI)

`GooseSwiftApp` → `RootView` (onboarding gate) → `AppShellView` (tabs):

- **Home**: `HomeDashboardView`, `HomeScoreViews`, `HomeTimelineViews`, `HomeHealthMonitorViews`
- **Health**: `HealthView` plus `Health*`, `Sleep*` and `SleepV2*` views, fed by `HealthDataStore` (+ extensions per metric family)
- **Coach**: `CoachView`, `CoachChatScreen`, `OpenAICoachResponsesClient`, `CodexEmbeddedAuth` (ChatGPT sign-in; optional)
- **More**: `MoreView`, `DeviceView`, `MoreCaptureViews`, `MoreDebugViews`, `MoreRawExportViews`, fed by `MoreDataStore`

Design rule used throughout: **never show fabricated numbers**. A metric is
live, local, bridge-derived, or "unavailable" with a reason
(see `docs/goose-swift-mvp/RemainingDataTodo.md`).

## Apple Health (HealthKit) today

- Reads: **body mass only** (`HealthKitProfileImporter`), used to prefill the profile.
- Writes: **none yet**. The README mentions workout writes, but the app
  requests no share permissions. Rust `health_sync.dry_run` only *plans*
  what a HealthKit write would contain.
- A Rust test (`ios_healthkit_boundary_tests.rs`) enforces the "weight-only"
  read boundary. Widening HealthKit reads means updating that test on purpose.

## Where to build the Apple Watch / Apple Health comparison

1. **Get the data out.** Use More → Raw Export, or the Files app
   (`UIFileSharingEnabled` is on), to copy `goose.sqlite` / export bundles to
   the Mac. Then analyze them with the Rust CLIs or Python.
2. **Read Apple Health in-app.** Add read types (heart rate, HRV SDNN,
   resting HR, sleep analysis, respiratory rate, SpO2, wrist temperature) to a
   new importer modelled on `HealthKitSleepImporter.swift`. Store the samples
   through a new bridge method, since `external_sleep_sessions` already exists
   for sleep, and update the boundary test.
3. **Compare.** `algorithm_compare.rs` and `metrics.reference_compare`
   already implement "Goose vs reference" reports. Apple Watch values can be
   added as another reference source.

## Known gaps (from the upstream author)

See `docs/goose-swift-mvp/RemainingDataTodo.md` and `recovery-todo.md`. In short,
sleep staging, recovery, SpO2, respiratory rate and skin temperature packet
semantics are still being reverse-engineered. Many screens will show empty
states until enough band data has been captured. Performance is known to be
poor in this alpha.
