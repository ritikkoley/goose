# Goose: notes for Claude

iOS app (SwiftUI) + Rust core that talks to WHOOP 5.0 bands over BLE. Read
`docs/ARCHITECTURE.md` before changing anything non-trivial.

- iOS builds need macOS + Xcode 26. In Linux/cloud sessions you can only build and test the Rust core:
  `cd Rust/core && cargo build --lib && cargo test --lib --bins`.
  Some integration tests (`command_tests`, `ios_healthkit_boundary_tests`, `reference_runner_cli_tests`,
  `tooling_inventory_tests`, parts of `local_health_validation_suite_cli_tests`) expect the upstream
  monorepo layout or Python reference libs and fail here. That is known and not a regression.
- Swift ↔ Rust boundary: one C function `goose_bridge_handle_json` (JSON in/out), routed in
  `Rust/core/src/bridge.rs`. New Rust features = new bridge method + Swift call via `GooseRustBridge`.
- Adding a Swift file requires adding it to `GooseSwift.xcodeproj/project.pbxproj` (no folder sync).
- Signing: `Config/Goose.xcconfig` (committed) includes gitignored `Config/Local.xcconfig`.
  Never commit a personal Team ID or bundle ID.
- Never show fabricated metric values in UI; show unavailable states with a reason.
- Style: 2-space Swift indentation, small typed models, extensions split by concern (`Type+Concern.swift`).
