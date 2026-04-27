# Macrodex

Macrodex is an iOS SwiftUI app for running Pi agent conversations from a mobile interface. It bundles Pi along with a calorie and macro dashboard, complete with HealthKit integration.

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

## Project Layout

- `Macrodex/` - SwiftUI app source, app resources, bridges, models, and views.
- `Packages/PiJSC/` - vendored Swift package for the JavaScriptCore Pi runtime.
- `docs/` - supporting SQL and implementation notes.
- `ci/` - local and GitHub Actions build support.
- `project.yml` - XcodeGen project definition.

## License

Licensed under the Apache License, Version 2.0. See `LICENSE` for details.
