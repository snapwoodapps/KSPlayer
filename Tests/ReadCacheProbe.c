#include "KSReadCache.h"
#include <Libavutil/time.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BLOCK (1024 * 1024)
static int cancelled;
static int64_t cancel_at;
static int interrupt(void *opaque) {
    (void)opaque;
    return cancelled || (cancel_at && av_gettime_relative() >= cancel_at);
}

static AVDictionary *http_options(void) {
    AVDictionary *options = NULL;
    const char *headers = getenv("KS_READ_CACHE_TEST_HEADERS");
    const char *ca = getenv("KS_READ_CACHE_TEST_CA");
    av_dict_set(&options, "rw_timeout", "5000000", 0);
    av_dict_set(&options, "headers", headers ? headers : "X-Cache-Test: preserved\r\n", 0);
    av_dict_set(&options, "tls_verify", "1", 0);
    if (ca) av_dict_set(&options, "ca_file", ca, 0);
    return options;
}

static int open_failure(const char *url) {
    KSReadCache *cache = NULL;
    AVDictionary *options = http_options();
    assert(ks_read_cache_open(&cache, url, options, NULL) < 0);
    assert(!cache);
    ks_read_cache_close(&cache);
    av_dict_free(&options);
    fprintf(stderr, "PASS failed/nonseekable open cleanup\n");
    return 0;
}

static int cancel_read(const char *url) {
    KSReadCache *cache = NULL;
    AVDictionary *options = http_options();
    AVIOInterruptCB cb = { .callback = interrupt };
    assert(ks_read_cache_open(&cache, url, options, &cb) == 0);
    int64_t begin = av_gettime_relative();
    cancel_at = begin + 200000;
    uint8_t data[100];
    assert(avio_read(ks_read_cache_context(cache), data, sizeof(data)) == AVERROR_EXIT);
    assert(av_gettime_relative() - begin < 2000000);
    assert(ks_read_cache_stats(cache).hits == 0);
    ks_read_cache_close(&cache);
    av_dict_free(&options);
    fprintf(stderr, "PASS interruption during HTTP read\n");
    return 0;
}

static void check_bytes(AVIOContext *io, int64_t offset, int length) {
    uint8_t data[256];
    assert(length <= (int)sizeof(data));
    assert(avio_seek(io, offset, SEEK_SET) == offset);
    assert(avio_read(io, data, length) == length);
    for (int i = 0; i < length; i++) assert(data[i] == (uint8_t)((offset + i) % 251));
}

static int bytes(const char *url, int expect_failure) {
    KSReadCache *cache = NULL;
    AVDictionary *options = http_options();
    av_dict_set(&options, "rw_timeout", "1000000", 0);
    AVIOInterruptCB cb = { .callback = interrupt };
    assert(ks_read_cache_open(&cache, url, options, &cb) == 0);
    assert(av_dict_get(options, "headers", NULL, 0)); // Options remain caller-owned.
    const char *headers = getenv("KS_READ_CACHE_TEST_HEADERS");
    if (headers) assert(!strcmp(av_dict_get(options, "headers", NULL, 0)->value, headers));
    AVIOContext *io = ks_read_cache_context(cache);
    if (expect_failure) {
        uint8_t data[32];
        assert(avio_read(io, data, sizeof(data)) < 0);
        assert(ks_read_cache_stats(cache).hits == 0);
    } else {
        const int64_t size = 8000000000LL;
        assert(avio_size(io) == size);
        // Repeated jumps between distant audio/video windows should hit cache.
        for (int i = 0; i < 12; i++) {
            check_bytes(io, 127 + i * 101, 100);
            check_bytes(io, 4294967296LL + 33 + i * 101, 100);
        }
        assert(ks_read_cache_stats(cache).misses == 2);
        check_bytes(io, BLOCK - 30, 100); // Read across a cache-block boundary.
        check_bytes(io, size - 17, 17);   // Partial final block.
        uint8_t data[100];
        assert(avio_read(io, data, 1) == AVERROR_EOF);
        // avio_seek itself accepts only SET/CUR; exercise the END callback.
        assert(io->seek(io->opaque, 0, SEEK_END) == size);
        assert(avio_seek(io, -1, SEEK_SET) < 0);
        for (int i = 3; i < 16; i++) check_bytes(io, (int64_t)i * BLOCK + 99, 100);
        check_bytes(io, 127, 100); // Evicted block must reload correctly.
        assert(ks_read_cache_stats(cache).allocated_bytes == 4 * BLOCK);
        KSReadCacheStats before = ks_read_cache_stats(cache);
        cancelled = 1;
        // Force a callback rather than consuming AVIO's already buffered bytes.
        assert(avio_seek(io, size / 2, SEEK_SET | AVSEEK_FORCE) == AVERROR_EXIT);
        assert(ks_read_cache_stats(cache).bytes_read == before.bytes_read);
    }
    ks_read_cache_close(&cache);
    assert(!cache);
    ks_read_cache_close(&cache); // Idempotent teardown, including partial opens.
    av_dict_free(&options);
    fprintf(stderr, "PASS %s\n", expect_failure ? "truncated response" : "byte/cache/cancellation contracts");
    return 0;
}

static int packets(const char *url, int cached, double seconds) {
    AVFormatContext *ctx = NULL;
    KSReadCache *cache = NULL;
    AVDictionary *options = http_options();
    if (cached) {
        assert(ks_read_cache_open(&cache, url, options, NULL) == 0);
        ctx = avformat_alloc_context();
        assert(ctx);
        ctx->pb = ks_read_cache_context(cache);
        ctx->flags |= AVFMT_FLAG_CUSTOM_IO;
    }
    assert(avformat_open_input(&ctx, url, NULL, &options) == 0);
    ctx->flags |= AVFMT_FLAG_GENPTS;
    assert(avformat_find_stream_info(ctx, NULL) == 0);
    int video = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    int audio = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, video, NULL, 0);
    assert(video >= 0);
    for (unsigned i = 0; i < ctx->nb_streams; i++)
        ctx->streams[i]->discard = ((int)i == video || (int)i == audio) ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
    AVPacket *packet = av_packet_alloc();
    assert(packet);
    const double fractions[] = {0, .45, .2, .7};
    for (int phase = 0; phase < 4; phase++) {
        double target = ctx->duration / (double)AV_TIME_BASE * fractions[phase];
        int64_t begin = av_gettime_relative();
        if (phase) assert(av_seek_frame(ctx, -1, (int64_t)(target * AV_TIME_BASE), AVSEEK_FLAG_BACKWARD) >= 0);
        double v = -1, a = -1;
        int count = 0;
        while (count++ < 200000 && av_read_frame(ctx, packet) >= 0) {
            double time = packet->pts * av_q2d(ctx->streams[packet->stream_index]->time_base);
            if (packet->stream_index == video) v = time;
            if (packet->stream_index == audio) a = time;
            uint64_t hash = 14695981039346656037ULL;
            for (int i = 0; i < packet->size; i++) hash = (hash ^ packet->data[i]) * 1099511628211ULL;
            printf("%d %d %lld %lld %lld %lld %d %llu\n", phase, packet->stream_index,
                   (long long)packet->pos, (long long)packet->pts, (long long)packet->dts,
                   (long long)packet->duration, packet->size, (unsigned long long)hash);
            av_packet_unref(packet);
            if (v > target + seconds && (audio < 0 || a > target + seconds)) break;
        }
        assert(v > target + seconds && (audio < 0 || a > target + seconds));
        fprintf(stderr, "seek=%.3f seconds=%.3f packets=%d\n", target, (av_gettime_relative() - begin) / 1e6, count);
    }
    if (cache) {
        KSReadCacheStats stats = ks_read_cache_stats(cache);
        assert(stats.allocated_bytes <= 4 * BLOCK);
        fprintf(stderr, "cache hits=%lld misses=%lld bytes=%lld allocated=%lld\n",
                (long long)stats.hits, (long long)stats.misses,
                (long long)stats.bytes_read, (long long)stats.allocated_bytes);
    }
    av_packet_free(&packet);
    avformat_close_input(&ctx);
    ks_read_cache_close(&cache);
    av_dict_free(&options);
    return 0;
}

int main(int argc, char **argv) {
    assert(argc >= 3);
    av_log_set_level(AV_LOG_ERROR);
    if (!strcmp(argv[1], "bytes")) return bytes(argv[2], 0);
    if (!strcmp(argv[1], "truncated")) return bytes(argv[2], 1);
    if (!strcmp(argv[1], "stream") || !strcmp(argv[1], "missing") || !strcmp(argv[1], "reject")) return open_failure(argv[2]);
    if (!strcmp(argv[1], "slow")) return cancel_read(argv[2]);
    assert(argc == 5);
    return packets(argv[2], atoi(argv[3]), atof(argv[4]));
}
