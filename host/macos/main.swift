// openbirds macOS host — minimal shell that proves Swift ↔ C ↔ Koka.
//
// On iOS this same FFI moves into a SwiftUI app's view body. The
// linkage and crossing-the-language-boundary story is identical;
// only the packaging changes.

import Foundation

guard let cstr = openbirds_greeting() else {
    fputs("openbirds: greeting() returned NULL\n", stderr)
    exit(1)
}
defer { openbirds_free(cstr) }

print(String(cString: cstr))
