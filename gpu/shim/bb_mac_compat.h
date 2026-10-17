// SPDX-License-Identifier: GPL-2.0-or-later
// bbport (macOS): Linux helpers the renderer uses for diagnostics and thread identity.
// Force-included into the GPU library on macOS only (CMakeLists.txt).
#pragma once
#ifdef __APPLE__
#include <pthread.h>
#include <sys/types.h>
// Mach thread port: unique per live thread, like a Linux TID.
static inline pid_t gettid(void) { return (pid_t)pthread_mach_thread_np(pthread_self()); }
#endif
