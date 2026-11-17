#include "KSReadCache.h"
#include <Libavutil/error.h>
#include <Libavutil/mem.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

// Separate windows retain audio and video even when they are far apart. A single
// large contiguous buffer would have to retain everything between those tracks.
#define KS_CACHE_BLOCK_SIZE (1024 * 1024)
#define KS_CACHE_BLOCK_COUNT 4
#define KS_IO_BUFFER_SIZE 32768

typedef struct KSReadCacheBlock {
    uint8_t *data;
    int64_t start;
    int length;
    uint64_t used;
} KSReadCacheBlock;

struct KSReadCache {
    AVIOContext *source;
    AVIOContext *context;
    AVIOInterruptCB interrupt;
    int64_t size;
    int64_t position;
    uint64_t clock;
    KSReadCacheBlock blocks[KS_CACHE_BLOCK_COUNT];
    KSReadCacheStats stats;
};

static int interrupted(const KSReadCache *cache) {
    return cache->interrupt.callback && cache->interrupt.callback(cache->interrupt.opaque);
}

static int read_packet(void *opaque, uint8_t *buffer, int length) {
    KSReadCache *cache = opaque;
    if (interrupted(cache)) return AVERROR_EXIT;
    if (length <= 0) return AVERROR(EINVAL);
    if (cache->position >= cache->size) return AVERROR_EOF;

    int64_t start = cache->position / KS_CACHE_BLOCK_SIZE * KS_CACHE_BLOCK_SIZE;
    KSReadCacheBlock *block = NULL;
    for (int i = 0; i < KS_CACHE_BLOCK_COUNT; i++) {
        if (cache->blocks[i].length && cache->blocks[i].start == start) {
            block = &cache->blocks[i];
            cache->stats.hits++;
            break;
        }
    }

    if (!block) {
        cache->stats.misses++;
        block = &cache->blocks[0];
        for (int i = 0; i < KS_CACHE_BLOCK_COUNT; i++) {
            if (!cache->blocks[i].length) { block = &cache->blocks[i]; break; }
            if (cache->blocks[i].used < block->used) block = &cache->blocks[i];
        }
        block->length = 0;
        if (!block->data) {
            block->data = av_malloc(KS_CACHE_BLOCK_SIZE);
            if (!block->data) return AVERROR(ENOMEM);
            cache->stats.allocated_bytes += KS_CACHE_BLOCK_SIZE;
        }

        int64_t result = avio_seek(cache->source, start, SEEK_SET);
        if (result != start) return result < 0 ? (int)result : AVERROR(EIO);
        int wanted = (int)FFMIN((int64_t)KS_CACHE_BLOCK_SIZE, cache->size - start);
        int received = 0;
        while (received < wanted) {
            if (interrupted(cache)) return AVERROR_EXIT;
            int count = avio_read(cache->source, block->data + received, wanted - received);
            if (count <= 0) return count < 0 && count != AVERROR_EOF ? count : AVERROR(EIO);
            received += count;
            cache->stats.bytes_read += count;
        }
        // Publish only a complete block. A short response must not become cached
        // success or silently change the promised file length.
        block->start = start;
        block->length = received;
    }

    block->used = ++cache->clock;
    int offset = (int)(cache->position - start);
    int count = FFMIN(length, block->length - offset);
    memcpy(buffer, block->data + offset, count);
    cache->position += count;
    return count;
}

static int64_t seek(void *opaque, int64_t offset, int whence) {
    KSReadCache *cache = opaque;
    if (interrupted(cache)) return AVERROR_EXIT;
    if (whence & AVSEEK_SIZE) return cache->size;
    whence &= ~AVSEEK_FORCE;
    int64_t base;
    switch (whence) {
        case SEEK_SET: base = 0; break;
        case SEEK_CUR: base = cache->position; break;
        case SEEK_END: base = cache->size; break;
        default: return AVERROR(EINVAL);
    }
    if (offset < -base || (offset > 0 && base > INT64_MAX - offset)) return AVERROR(EINVAL);
    // Seeking is logical only. The next read fetches at most one missing block;
    // large user seeks never read through the intervening movie data.
    cache->position = base + offset;
    return cache->position;
}

int ks_read_cache_open(KSReadCache **result, const char *url,
                       const AVDictionary *options, const AVIOInterruptCB *interrupt) {
    if (!result || *result || !url) return AVERROR(EINVAL);
    KSReadCache *cache = av_mallocz(sizeof(*cache));
    if (!cache) return AVERROR(ENOMEM);
    if (interrupt) cache->interrupt = *interrupt;
    AVDictionary *io_options = NULL;
    int status = av_dict_copy(&io_options, options, 0);
    if (status >= 0) status = avio_open2(&cache->source, url, AVIO_FLAG_READ, &cache->interrupt, &io_options);
    av_dict_free(&io_options);
    if (status < 0) goto fail;
    cache->size = avio_size(cache->source);
    if (cache->size <= 0 || !(cache->source->seekable & AVIO_SEEKABLE_NORMAL)) {
        status = AVERROR(ENOSYS);
        goto fail;
    }
    uint8_t *buffer = av_malloc(KS_IO_BUFFER_SIZE);
    if (!buffer) { status = AVERROR(ENOMEM); goto fail; }
    cache->context = avio_alloc_context(buffer, KS_IO_BUFFER_SIZE, 0, cache, read_packet, NULL, seek);
    if (!cache->context) { av_free(buffer); status = AVERROR(ENOMEM); goto fail; }
    *result = cache;
    return 0;
fail:
    ks_read_cache_close(&cache);
    return status;
}

AVIOContext *ks_read_cache_context(KSReadCache *cache) {
    return cache ? cache->context : NULL;
}

KSReadCacheStats ks_read_cache_stats(const KSReadCache *cache) {
    return cache ? cache->stats : (KSReadCacheStats){0};
}

void ks_read_cache_close(KSReadCache **reference) {
    if (!reference || !*reference) return;
    KSReadCache *cache = *reference;
    *reference = NULL;
    if (cache->context) {
        // libavformat may replace the original AVIO buffer during probing.
        av_freep(&cache->context->buffer);
        avio_context_free(&cache->context);
    }
    avio_closep(&cache->source);
    for (int i = 0; i < KS_CACHE_BLOCK_COUNT; i++) av_free(cache->blocks[i].data);
    av_free(cache);
}
