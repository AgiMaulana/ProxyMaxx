# Repository Guidelines

## Project Overview
ProxyMaxx is a free, open-source HTTP/HTTPS debugging proxy for macOS (MIT licensed), built with SwiftNIO and SwiftUI. It features a native macOS desktop application, a headless CLI (`proxymaxx-cli`), a native browser extension host (`proxymaxx-browser-host`), Chromium/Firefox extensions, and an Android VPN tunnel companion (`Android/ProxyMaxxVpn`).

## Architecture & Data Flow
- **Proxy Engine (`ProxyKit`)**: SwiftNIO-based HTTP/1.1 proxy with TLS interception (man-in-the-middle via `CertKit`), SOCKS5 listener, and raw WebSocket relay.
- **Core Modules (`Package.swift`)**:
  - `ProxyKit`: Networking, NIO channel handlers, proxy engine.
  - `FlowKit`: HTTP flow capture, storage, zstd/brotli decompression.
  - `CertKit`: Root CA generation and X.509 certificate management using `swift-certificates`.
  - `RuleKit`: Map Local rules, ZIP bundle archives (`ZIPFoundation`), and rule stores.
  - `SystemKit`: macOS system proxy control, browser bridge integration, and Android toolchain/installers.
  - `ClientKit`: Local process attribution using `libproc` socket matching.
  - `CodeGenKit`: Code generation helpers (e.g. cURL commands).
  - `Branding`: Shared product identity.
- **Frontends / Binaries**:
  - `ProxyMaxxApp`: SwiftUI macOS application (`Sources/ProxyMaxxApp`).
  - `ProxyMaxxCLI`: Headless CLI driver for scripts and AI agents (`cli/`).
  - `BrowserHost`: Native messaging host for browser extensions (`BrowserHost/`).
- **Data Flow**: Intercepted flows are recorded into an append-only NDJSON session log (`session.ndjson`) and synchronized across front-ends via IPC channels (`ipc/flows/`, `proxy-registry.json`, `browser-bridge.json`).

## Key Directories
- `Sources/`: SwiftPM library and executable targets (`ProxyMaxxApp`, `SystemKit`, `BrowserHost`, `ClientKit`, `ProxyKit`, `FlowKit`, `RuleKit`, `CodeGenKit`, `Branding`).
- `cli/`: Headless command-line interface (`proxymaxx-cli`).
- `Browser/`: Chromium and Firefox extension sources (`ProxyMaxxExtension/`, `FirefoxExtension/`).
- `Android/`: Android VPN tunnel app (`ProxyMaxxVpn/`).
- `Scripts/`: Build, packaging, and runner scripts (`bundle-app.sh`, `run.sh`, `build-cli.sh`, `build-browser-extension.sh`, `build-all.sh`, `build-android-vpn.sh`).
- `Tests/`: Unit and integration test targets (`ProxyKitTests`, `FlowKitTests`, `RuleKitTests`, `ClientKitTests`, `CodeGenKitTests`, `CertKitTests`, `SystemKitTests`).
- `Resources/`: Bundled icons, localization (`en.lproj`), android assets, and staged binaries.
- `docs/`: User documentation, screenshots, and guides (`android-vpn-protocol.md`, `android.md`).
- `site/`: Documentation website (`index.html`, `styles.css`, `script.js`).

## Development Commands
- **Build All Swift Targets**: `swift build`
- **Run Tests**: `swift test`
- **Run macOS App (Recommended with localized assets)**:
  - `Scripts/run.sh`
  - `Scripts/run.sh debug --autostart --port 9090`
- **Build CLI**:
  - `swift build --product proxymaxx-cli`
  - `Scripts/build-cli.sh` (copies to `Resources/proxymaxx-cli`)
- **Build Browser Extensions**:
  - `Scripts/build-browser-extension.sh`
- **Bundle macOS App (`dist/ProxyMaxx.app`)**:
  - `Scripts/bundle-app.sh`
  - `Scripts/bundle-app.sh release --with-android-vpn`
- **CI Build**:
  - `Scripts/build-all.sh release`

## Code Conventions & Common Patterns
- **Formatting & Style**: Swift standard library and Swift 5.10 conventions, strict typing, explicit module visibility where appropriate.
- **Naming**: CamelCase for types/protocols, camelCase for properties/methods, descriptive variable names, avoiding generic placeholder names.
- **Error Handling**: Swift throwing functions, explicit error types, and robust JSON/NDJSON encoding/decoding errors.
- **Async Patterns**: Swift concurrency (`async`/`await`) alongside SwiftNIO event loops and callbacks where network I/O demands low-allocation non-blocking event-driven handling.
- **Dependency Management**: Swift Package Manager (`Package.swift`) with pinned versions (SwiftNIO, swift-certificates, ZIPFoundation, etc.).
- **State Management**: SwiftUI `@StateObject`, `@ObservedObject`, centralized in `AppModel` and engine state registries.

## Important Files
- `Package.swift`: SwiftPM project definition, targets, and dependencies.
- `Sources/ProxyMaxxApp/ProxyMaxxApp.swift`: SwiftUI app entry point.
- `Sources/ProxyMaxxApp/AppModel.swift`: Central application state model and coordination.
- `cli/Main.swift`: CLI entry point (`proxymaxx-cli`).
- `BrowserHost/main.swift`: Browser native messaging host entry point.
- `Scripts/bundle-app.sh`: Primary packaging script for `.app` bundle and companion binaries.

## Runtime/Tooling Preferences
- **Required Runtime**: macOS 14.0 (`.macOS(.v14)`), Swift 5.10 (`// swift-tools-version: 5.10`).
- **Package Manager**: SwiftPM (`swift`), Homebrew (`brew`) for cask/dependencies.
- **Tooling Constraints**: Ad-hoc signed macOS binaries, strict separation of UI and headless engines via IPC / session logs.

## Testing & QA
- **Test Frameworks**: SwiftPM test targets (`XCTest` / Swift Testing conventions).
- **Running Tests**: `swift test` (runs all unit, integration, and proxy end-to-end tests across `ProxyKitTests`, `FlowKitTests`, `RuleKitTests`, `ClientKitTests`, `CodeGenKitTests`, `CertKitTests`, `SystemKitTests`).
- **Integration Tests**: Tests drive the proxy engine with real `curl` commands and simulated client attribution.
