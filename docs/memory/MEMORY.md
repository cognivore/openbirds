# openbirds memory index

- [openbirds stack and architecture](openbirds_stack.md) — Koka + Nix + pixel framebuffer; iOS+Android primary; rejections of Rust/Flutter/Haskell with reasons
- [Declarative workflow only](feedback_declarative_workflow.md) — no Xcode/Android Studio clicking; xcodegen/xcodebuild/simctl + Justfile
- [User technical preferences](user_preferences.md) — strong effect discipline, Nix-default, clawed-cogworker as canonical pattern, pixel-art aesthetic
- [kklib iOS fork pending](project_kklib_ios_fork.md) — os.c uses macOS-only APIs; openbirds skips it today via custom unity, upstream PR is the right long-term fix
- [Xcode 26 linker traps](project_xcode26_linker_traps.md) — ENABLE_DEBUG_DYLIB=NO + LD=clang + module map (not bridging header) are the working iOS project.yml combo
- [Thin shell architecture](project_thin_shell_architecture.md) — mcmonad-style: Swift is a thin servant (MTKView/input/native), Koka is the brain (rendering/animation/state). One-way IPC via FFI.
- [Koka perf traps for hot loops](project_koka_perf_traps.md) — `kk_vector_unsafe_assign` drops the vector; mutual tail calls don't TCO. Working LZW pattern in `koka/lzw.kk`.
- [Koka codegen hang threshold](project_koka_codegen_param_threshold.md) — bool + heap + effect interactions push the recursive-function arg threshold below the documented 12; default to bundling all loop state into a heap `pub struct`
- [Sticky chrome deferred to WM](project_sticky_chrome_for_wm.md) — first scroll v1 had ad-hoc sticky top/bottom bands; ripped out because sticky regions should be a foundational primitive of the eventual framebuffer-as-window-manager layer, not bolted onto typography
- [SwiftUI .ignoresSafeArea zeroes geo.safeAreaInsets](feedback_swiftui_safearea_ignoresafe_zeroes_geo.md) — read true device insets off UIWindow.safeAreaInsets via UIApplication.connectedScenes when full-bleed rendering
- [Mirror auto-memory into the repo](feedback_mirror_memory_into_repo.md) — every commit of substance: cp ~/.claude/.../memory/*.md docs/memory/ and stage alongside code
