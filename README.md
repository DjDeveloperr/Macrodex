# Macrodex

Macrodex is an iOS SwiftUI app for Macrodex Agent conversations, calorie/macro tracking, and HealthKit integration.

## Requirements

- Xcode 16+
- iOS 18.0+ target support
- XcodeGen (only if you change `project.yml`)

## Setup

```sh
git clone https://github.com/DjDeveloperr/Macrodex
cd Macrodex
```

Open `Macrodex.xcodeproj` in Xcode and build the `Macrodex` scheme.

If you update `project.yml`, regenerate the project:

```sh
xcodegen generate
```

Command-line simulator build:

```sh
ci/build-ios-simulator.sh
```

## Optional: SwiftUI preview workflow

For SimDeck-backed preview reloads:

```sh
scripts/preview-swiftui.sh Macrodex/Views/BrandLogo.swift --preview "Brand Logo" --rebuild-host
scripts/preview-swiftui.sh Macrodex/Views/BrandLogo.swift --preview "Brand Logo" --watch
```

Use `--force-xcode-build` after dependency or project-setting changes.

## Project Layout

- `Macrodex/` — app source and resources
- `Packages/MacrodexAgent/` — vendored native agent package
- `docs/` — SQL and implementation notes
- `ci/` — build scripts/workflow support
- `project.yml` — XcodeGen definition

## License

Licensed under the Apache License, Version 2.0. See `LICENSE` for details.
