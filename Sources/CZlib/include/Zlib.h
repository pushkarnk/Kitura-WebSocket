#include <zlib.h>

static inline int CZlib_deflateInit2(z_streamp strm,
                                           int level,
                                           int method,
                                           int windowBits,
                                           int memLevel,
                                           int strategy) {
    return deflateInit2(strm, level, method, windowBits, memLevel, strategy);
}

static inline int CZlib_inflateInit2(z_streamp strm, int windowBits) {
    return inflateInit2(strm, windowBits);
}
