# Declarative workflow only — no IDE clicking

All development workflows for openbirds are declarative and
CLI-driven. No "open Xcode and click File → New", no "select
target in dropdown", no GUI configuration.

## Why

Reproducibility, code-review-ability, and "the build my colleague
runs is the build I run" all depend on the workflow being a script
you can read in git, not a sequence of clicks no one wrote down.

## How (rules)

- **iOS project structure:** declared in `host/ios/project.yml`,
  generated with `xcodegen`. Never hand-edit `.xcodeproj` or open
  it for config.
- **Builds:** `xcodebuild` from the command line, parameters as
  flags.
- **Simulators:** `xcrun simctl` for boot / install / launch / log /
  screenshot.
- **Devices:** `xcrun devicectl` for install + launch on a real
  iPhone over USB.
- **Android equivalent (later):** Gradle from CLI, no Android
  Studio.
- **Generated `.xcodeproj` directories are gitignored** — they
  regenerate from `project.yml`.
- **One task runner**, `Justfile`, so all common workflows have a
  single CLI invocation. New workflows become new `just` recipes;
  documentation lives in the recipe comments.
- If a tool only offers a GUI path, find a CLI alternative or
  write one — do not punt to "open the IDE."

## When the IDE is allowed

The Xcode IDE is allowed for *reading* code or interactive
debugging if the user chooses, but **the canonical workflow must
work without it**.

The one historical exception: personal-team device signing on
first build. The Xcode UI writes account-UUID + provisioning
profile bindings into the `.xcodeproj` that aren't reproducible
from `project.yml`. The Justfile's `ios-build-device` recipe
deliberately does NOT regenerate the project (`ios-project`); it
expects the IDE-bound signing to already be in place. If you need
to regenerate, run `just ios-project` separately and re-bind
signing in Xcode one time.
