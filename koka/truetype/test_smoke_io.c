// koka/truetype/test_smoke_io.c — file-read FFI for the smoke test.
//
// This is the only C in the truetype port: a POSIX file-slurper that
// hands the TTF bytes to Koka as a `vector<int>` (one int per byte,
// values 0..255). Same pattern bridge.c uses to load GIFs into the
// runtime.

#include <stdio.h>
#include <stdlib.h>

static kk_vector_t openbirds_truetype_read_file(kk_string_t path_k, kk_context_t* ctx) {
    const char* path = kk_string_cbuf_borrow(path_k, NULL, ctx);

    FILE* f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "test_smoke_io: cannot open %s\n", path);
        kk_string_drop(path_k, ctx);
        // Return an empty vector — the caller throws.
        kk_box_t* unused = NULL;
        return kk_vector_alloc_uninit(0, &unused, ctx);
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);

    unsigned char* bytes = (unsigned char*)malloc((size_t)sz);
    size_t nread = fread(bytes, 1, (size_t)sz, f);
    fclose(f);
    kk_string_drop(path_k, ctx);

    if (nread != (size_t)sz) {
        fprintf(stderr, "test_smoke_io: short read on %s\n", path);
        free(bytes);
        kk_box_t* unused = NULL;
        return kk_vector_alloc_uninit(0, &unused, ctx);
    }

    kk_box_t* buf = NULL;
    kk_vector_t v = kk_vector_alloc_uninit((kk_ssize_t)sz, &buf, ctx);
    for (kk_ssize_t i = 0; i < (kk_ssize_t)sz; i++) {
        buf[i] = kk_integer_box(kk_integer_from_int32((int32_t)bytes[i], ctx), ctx);
    }
    free(bytes);
    return v;
}
