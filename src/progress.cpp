#include "progress.h"
#include "terminal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <time.h>
#endif

static uint64_t Milliseconds() {
#ifdef _WIN32
    return (uint64_t)GetTickCount64();
#else
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (uint64_t)time.tv_sec * 1000 + (uint64_t)time.tv_nsec / 1000000;
#endif
}

void StartProgress(Progress* progress, const char* operation, const char* name, size_t name_size) {
    const char* terminal = getenv("TERM");
    if ((terminal && !strcmp(terminal, "dumb")) || !IsTerminal(stderr)) return;
    const char* no_color = getenv("NO_COLOR");
    progress->enabled = true;
    progress->decorated = !no_color || !*no_color;
    progress->operation = operation;
    progress->name = name;
    progress->name_size = name_size;
    progress->started = Milliseconds();
}

static void PrintBytes(int64_t received, int64_t total) {
    static const char* units[] = {"B", "KiB", "MiB", "GiB", "TiB"};
    int64_t scale = total > 0 ? total : received;
    int unit = 0;
    double divisor = 1;
    while (scale >= 1024 && unit < 4) {
        scale /= 1024;
        divisor *= 1024;
        ++unit;
    }
    if (total > 0 && unit == 0)
        fprintf(stderr, "%lld / %lld B", (long long)received, (long long)total);
    else if (total > 0)
        fprintf(stderr, "%.1f / %.1f %s",
                (double)received / divisor, (double)total / divisor, units[unit]);
    else if (unit == 0)
        fprintf(stderr, "%lld B", (long long)received);
    else
        fprintf(stderr, "%.1f %s", (double)received / divisor, units[unit]);
}

void RenderProgress(Progress* progress, int64_t total, int64_t received) {
    if (!progress->enabled || (received <= 0 && !progress->finalizing)) return;
    uint64_t now = Milliseconds();
    if (!progress->visible) {
        if (now - progress->started < 200) return;
        progress->visible = true;
    } else if (progress->total == total && progress->received == received && !progress->finalizing) {
        return;
    } else if (now - progress->updated < 100 && !(total > 0 && received >= total)) {
        return;
    }
    progress->updated = now;
    progress->total = total;
    progress->received = received;
    fputs("\r\x1b[2K", stderr);
    fputs(progress->finalizing ? "Finalizing" : progress->operation, stderr);
    fputc(' ', stderr);
    if (progress->decorated) fputs("\x1b[1m", stderr);
    fwrite(progress->name, 1, progress->name_size, stderr);
    if (progress->decorated) fputs("\x1b[22m", stderr);
    if (progress->finalizing) { fflush(stderr); return; }
    if (total > 0) {
        int percent = (int)((double)received * 100.0 / (double)total);
        if (percent < 0) percent = 0;
        int maximum = !strcmp(progress->operation, "Extracting") ? 99 : 100;
        if (percent > maximum) percent = maximum;
        fprintf(stderr, "  %d%%  ", percent);
    } else {
        fputs("  ", stderr);
    }
    if (progress->decorated) fputs("\x1b[2m", stderr);
    PrintBytes(received, total);
    if (progress->decorated) fputs("\x1b[22m", stderr);
    fflush(stderr);
}

void FinalizeProgress(Progress* progress) {
    progress->finalizing = true;
    progress->updated = 0;
    RenderProgress(progress, progress->total, progress->received);
}

void ClearProgress(Progress* progress) {
    if (!progress->visible) return;
    fputs("\r\x1b[2K", stderr);
    fflush(stderr);
    progress->visible = false;
}

