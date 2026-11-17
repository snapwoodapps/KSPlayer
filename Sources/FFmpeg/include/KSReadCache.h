#ifndef KS_READ_CACHE_H
#define KS_READ_CACHE_H

#include <Libavformat/avformat.h>

typedef struct KSReadCache KSReadCache;

typedef struct KSReadCacheStats {
    int64_t hits;
    int64_t misses;
    int64_t bytes_read;
    int64_t allocated_bytes;
} KSReadCacheStats;

// Owns a seekable source and a custom, read-only AVIOContext. All operations,
// including close, must run on the demuxer's serialized open/read/close queue.
// Options are copied; the caller retains its dictionary and interrupt opaque.
int ks_read_cache_open(KSReadCache **cache, const char *url,
                       const AVDictionary *options, const AVIOInterruptCB *interrupt);
AVIOContext *ks_read_cache_context(KSReadCache *cache);
KSReadCacheStats ks_read_cache_stats(const KSReadCache *cache);
// Close the AVFormatContext first; AVFMT_FLAG_CUSTOM_IO leaves this owner intact.
void ks_read_cache_close(KSReadCache **cache);

#endif
