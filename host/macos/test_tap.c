// Tiny C smoke test for the close-button + exit FFI path. Run via:
//   clang -O0 host/macos/test_tap.c -L build -lopenbirds \
//     -Xlinker -rpath -Xlinker @executable_path/build -o build/test_tap
//   ./build/test_tap
// Expect output:
//   pre-tap should_exit: 0
//   post-tap (off-button) should_exit: 0
//   post-tap (on-button) should_exit: 1

#include <stdio.h>
#include "bridge.h"

int main(void) {
    double t = 0.0;
    printf("pre-tap should_exit: %d\n", openbirds_should_exit(t));

    // Tap somewhere away from the button (top-left corner).
    openbirds_tap(10, 10, 256, 256, t);
    printf("post-tap (off-button) should_exit: %d\n", openbirds_should_exit(t));

    // Tap inside the button area (button is bottom 15% of the canvas
    // — at 256x256, that's y >= 218; tap at center). Should NOT
    // exit yet — the brain plays the goodbye animation first.
    openbirds_tap(128, 230, 256, 256, t);
    printf("post-tap (on-button, t=0)    should_exit: %d\n", openbirds_should_exit(t));

    // Same scene-cell but t advanced past exit-delay-s (3.0).
    t = 4.0;
    printf("post-tap (on-button, t=4.0)  should_exit: %d\n", openbirds_should_exit(t));

    return 0;
}
