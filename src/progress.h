#pragma once

#include <stdint.h>
#include <stddef.h>

struct Progress {
    const char* operation;
    const char* name;
    size_t name_size;
    uint64_t started;
    uint64_t updated;
    int64_t total;
    int64_t received;
    bool enabled;
    bool finalizing;
    bool visible;
    bool decorated;
};

void StartProgress(Progress* progress, const char* operation, const char* name, size_t name_size);
void RenderProgress(Progress* progress, int64_t total, int64_t received);
void FinalizeProgress(Progress* progress);
void ClearProgress(Progress* progress);
