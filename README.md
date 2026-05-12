# NexAsk

Standalone repository for the `NexAsk` macOS app.

## What Is Included

- `Sources/` for the app host, shared runtime, and ASK-specific modules
- `Tests/` for the extracted Swift test suite
- `BuiltinSkills/` and `SkillStore/` assets bundled into the app
- `Resources/`, `Vendor/`, `VERSION`, and packaging scripts needed to build distributable artifacts from this repo directly

## Common Commands

```bash
swift build
swift test
./scripts/build.sh
./scripts/package.sh
./scripts/install.sh
./scripts/release.sh
./scripts/smoke_installed.sh
./scripts/smoke_ui.sh
```

## Output

- `swift build` and `swift test` use SwiftPM directly
- `./scripts/build.sh` emits `dist/NexAsk.app`
- `./scripts/package.sh` creates the signed zip and dmg artifacts under `dist/`
- `./scripts/release.sh` runs checks, builds, packages, and writes `dist/release_manifest.json`

## Quick Install (Local Development)

Standard build-and-install flow for local development:

```bash
./scripts/build.sh      # Build → dist/NexAsk.app
./scripts/install.sh     # Install → /Applications/NexAsk.app
open /Applications/NexAsk.app
```

The app runs as a menu-bar agent (`LSUIElement = true`) — look for its icon in the macOS menu bar after launch.

## Interaction Guide

- **Status bar menu**: Click the menu bar icon to open a dropdown menu with "New Conversation", "Settings", and other options
- **Alt + Drag**: Hold the Alt (Option) key and drag the mouse to draw a box anywhere on screen — a conversation window opens at that location
- **Esc**: Press Esc to close the current conversation window
- **Permissions**: On first launch the app will request Accessibility permission (required for Alt+drag). If prompted, grant it in System Settings → Privacy & Security → Accessibility

## Network & Proxy

NexAsk 的后端通信（设备注册、AI 配置、LLM 代理）全部通过 `https://api.nefish.net` 进行。为了避免本地代理工具（如 Clash、Upnet 等）干扰连接，APP 内所有到后端的 URLSession 请求均**绕过系统代理**（通过 `connectionProxyDictionary = [:]` 实现）。

如果你的代理工具正确配置了对 `api.nefish.net` 的路由，也可以手动移除此绕过逻辑。

## Notes

- Packaging scripts expect the vendored Sparkle framework under `Vendor/Sparkle`
- Build metadata is read from `VERSION` and the current git history
- Product configuration lives in `scripts/app_config.sh`
