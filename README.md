# Macrodex

Macrodex is an iOS SwiftUI app for running Macrodex Agent conversations from a mobile interface, paired with a calorie and macro dashboard and HealthKit integration.

## Requirements

- Xcode 16 or newer.
- iOS 18.0 or newer for the app target.
- XcodeGen if you change `project.yml`.

## Setup

Clone the repository:

```sh
git clone https://github.com/DjDeveloperr/Macrodex
cd Macrodex
```

Open `Macrodex.xcodeproj` in Xcode and build the `Macrodex` scheme for an iOS device or simulator.

The Xcode project is described by `project.yml`. If you change project structure or build settings there, regenerate the project with XcodeGen:

```sh
xcodegen generate
```

For a command-line simulator build:

```sh
ci/build-ios-simulator.sh
```

For fast SimDeck-backed SwiftUI preview reloads, boot an iOS simulator and run:

```sh
scripts/preview-swiftui.sh Macrodex/Views/BrandLogo.swift --preview "Brand Logo" --rebuild-host
scripts/preview-swiftui.sh Macrodex/Views/BrandLogo.swift --preview "Brand Logo" --watch
```

The wrapper uses the `Macrodex` scheme, a local `.simdeck-preview/` DerivedData/build cache, and unsigned simulator reload dylibs by default. Pass `--force-xcode-build` after changing project settings or dependencies. `--split-compile` is available for isolated views, but the compatible default is better for Macrodex previews that reference shared app helpers.

Debug builds also start the SimDeck Swift inspector agent and tag the root view as `macrodex.root`. The raw UIKit tree remains available immediately; full SwiftUI tree publishing should be attached lower in the hierarchy where the view does not require root environment values during reflection.

## Project Layout

- `Macrodex/` - SwiftUI app source, app resources, bridges, models, and views.
- `Packages/MacrodexAgent/` - vendored Swift package for the native Macrodex Agent runtime.
- `docs/` - supporting SQL and implementation notes.
- `ci/` - local and GitHub Actions build support.
- `project.yml` - XcodeGen project definition.

## License

Licensed under the Apache License, Version 2.0. See `LICENSE` for details.
