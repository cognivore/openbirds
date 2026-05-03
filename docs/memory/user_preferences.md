---
name: user technical preferences and style
description: How the user likes to architect projects — strong type discipline, Nix-everywhere, declarative tooling, clawed-cogworker as canonical pattern
type: user
originSessionId: 96f7f6ca-4d02-4a6f-bbf7-077f264f7c89
---
User profile for technical work:

- **Strong preference for type-level effect discipline.** Considers Rust "too weak when it comes to separation of effectful things and real things." Comfortable with tagless final, effect handlers, monadic effects.
- **Nix is the default packaging/dev-env mechanism.** Comfortable writing flakes, devshells, and home-manager modules. Treats Nix as a baseline, not an exotic dependency.
- **Canonical Nix pattern is clawed-cogworker** (`/Users/sweater/Github/clawed-cogworker`): `nixpkgs-unstable` + `flake-utils.eachDefaultSystem`, `nix/package.nix` via `callPackage`, separate `nix/home-manager.nix` for services. Mirror this shape for sibling projects.
- **Architectural discipline matters.** clawed-cogworker's CLAUDE.md enforces: zero I/O in library crates, port traits for all external interactions, validated newtypes, append-only logs, lints enforced at workspace level. This style should apply to new projects too.
- **Performance matters on high-end devices.** Rejected Flutter for Finch's jank. Wants apps that feel snappy on flagship phones.
- **Aesthetic preference: pixel art + color only** for openbirds. Influenced by Hundred Rabbits.
- **Tone:** direct, energetic, trusts strong opinions if backed by reasoning. Pushes back on overengineering. Uses casual register ("mate").

How to apply:
- When proposing tech, lead with the type-system / effect story, not just perf or ecosystem size.
- Default to Nix flakes for any new project; ask before using something else.
- For mobile/native work, prefer compiled languages with effect typing or strong functional patterns.
- For UI work in openbirds specifically, propose pixel-art solutions, not "use SwiftUI components."
