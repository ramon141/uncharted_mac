/* macOS (x86_64 under Rosetta 2) counterparts of the Linux calls the runtime uses. Included
 * through runtime.h, so the macros below only replace calls in this project's own sources. */
#ifndef BB_COMPAT_MAC_H
#define BB_COMPAT_MAC_H
#ifdef __APPLE__
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/types.h>
#include <sys/stat.h>

/* Mach thread port: unique per live thread, like a Linux TID. */
static inline pid_t compat_gettid(void) { return (pid_t)pthread_mach_thread_np(pthread_self()); }
#define gettid compat_gettid

/* struct stat names its timespec fields st_*timespec. */
#define st_atim st_atimespec
#define st_mtim st_mtimespec
#define st_ctim st_ctimespec

#ifndef CLOCK_REALTIME_COARSE
#define CLOCK_REALTIME_COARSE CLOCK_REALTIME
#endif
#ifndef PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP
#define PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP PTHREAD_RECURSIVE_MUTEX_INITIALIZER
#endif

/* Cryptographic random bytes (getrandom with flags 0 never returns short for these sizes). */
static inline ssize_t compat_getrandom(void *buffer, size_t size, unsigned flags) {
    (void)flags;
    arc4random_buf(buffer, size);
    return (ssize_t)size;
}
#define getrandom compat_getrandom

/* Sleeps until an absolute CLOCK_MONOTONIC time (no clock_nanosleep on macOS). */
static inline void compat_sleep_until_monotonic(const struct timespec *deadline) {
    for (;;) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        int64_t left = (int64_t)(deadline->tv_sec - now.tv_sec) * 1000000000 + (deadline->tv_nsec - now.tv_nsec);
        if (left <= 0) return;
        struct timespec t = {(time_t)(left / 1000000000), (long)(left % 1000000000)};
        nanosleep(&t, NULL);
    }
}

/* No timed mutex/rwlock locks on macOS: try again until the CLOCK_REALTIME deadline, sleeping
 * 50 us to 1 ms between attempts. PS4 games use them for short waits only. */
static inline int compat_timed_retry(int (*attempt)(void *), void *lock, const struct timespec *deadline) {
    if (deadline->tv_nsec < 0 || deadline->tv_nsec >= 1000000000) return EINVAL;
    long pause = 50000;
    for (;;) {
        int e = attempt(lock);
        if (e != EBUSY) return e;
        struct timespec now;
        clock_gettime(CLOCK_REALTIME, &now);
        if (now.tv_sec > deadline->tv_sec || (now.tv_sec == deadline->tv_sec && now.tv_nsec >= deadline->tv_nsec))
            return ETIMEDOUT;
        struct timespec t = {0, pause};
        nanosleep(&t, NULL);
        if (pause < 1000000) pause *= 2;
    }
}
static inline int compat_try_mutex(void *m) { return pthread_mutex_trylock(m); }
static inline int compat_try_rdlock(void *r) { return pthread_rwlock_tryrdlock(r); }
static inline int compat_try_wrlock(void *r) { return pthread_rwlock_trywrlock(r); }
static inline int compat_mutex_timedlock(pthread_mutex_t *m, const struct timespec *deadline) {
    return compat_timed_retry(compat_try_mutex, m, deadline);
}
static inline int compat_rwlock_timedrdlock(pthread_rwlock_t *r, const struct timespec *deadline) {
    return compat_timed_retry(compat_try_rdlock, r, deadline);
}
static inline int compat_rwlock_timedwrlock(pthread_rwlock_t *r, const struct timespec *deadline) {
    return compat_timed_retry(compat_try_wrlock, r, deadline);
}
#define pthread_mutex_timedlock compat_mutex_timedlock
#define pthread_rwlock_timedrdlock compat_rwlock_timedrdlock
#define pthread_rwlock_timedwrlock compat_rwlock_timedwrlock
#endif
#endif
