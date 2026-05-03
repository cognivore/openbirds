---
name: declarative workflow only — no IDE clicking
description: User insists on CLI/declarative-only development; never instruct them to click around in Xcode or Android Studio
type: feedback
originSessionId: 96f7f6ca-4d02-4a6f-bbf7-077f264f7c89
---
All development workflows for openbirds must be declarative and CLI-driven. No "open Xcode and click File → New", no "select target in dropdown", no GUI configuration.

**Why:** User explicitly stated "I need to make sure that we can stay within confines of declarativeness and never do any click-click-click for performing developing." This is a hard constraint, not a preference.

**How to apply:**
- iOS project structure: declare in `project.yml`, generate with `xcodegen`. Never hand-edit `.xcodeproj` or open it for config.
- Builds: `xcodebuild` from the command line, parameters as flags.
- Simulators: `xcrun simctl` for boot/install/launch/log.
- Android equivalent later: Gradle from CLI, no Android Studio.
- Generated `.xcodeproj` directories should be gitignored (regenerated from `project.yml`).
- Use a task runner (Justfile) so all common workflows have a single CLI invocation.
- If a tool only offers a GUI path, find a CLI alternative or write one — do not punt to "open the IDE."
- The IDE is allowed for *reading* code or debugging if the user chooses, but the canonical workflow must work without it.
