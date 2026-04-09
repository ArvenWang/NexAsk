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

## Notes

- Packaging scripts expect the vendored Sparkle framework under `Vendor/Sparkle`
- Build metadata is read from `VERSION` and the current git history
- Product configuration lives in `scripts/app_config.sh`
