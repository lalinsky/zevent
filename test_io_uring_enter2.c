#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <linux/io_uring.h>
#include <string.h>
#include <errno.h>
#include <time.h>

#define IORING_ENTER_EXT_ARG (1U << 3)
#define IORING_ENTER_GETEVENTS (1U << 0)

int main() {
    struct io_uring_params params;
    memset(&params, 0, sizeof(params));

    // Create io_uring
    int ring_fd = syscall(__NR_io_uring_setup, 256, &params);
    if (ring_fd < 0) {
        perror("io_uring_setup");
        return 1;
    }

    printf("io_uring fd=%d\n", ring_fd);

    // Setup timeout - 50ms
    struct __kernel_timespec ts;
    ts.tv_sec = 0;
    ts.tv_nsec = 50000000;

    struct io_uring_getevents_arg arg;
    memset(&arg, 0, sizeof(arg));
    arg.ts = (__u64)&ts;

    printf("Calling io_uring_enter2:\n");
    printf("  fd=%d\n", ring_fd);
    printf("  to_submit=0\n");
    printf("  min_complete=0\n");
    printf("  flags=0x%x (GETEVENTS | EXT_ARG)\n", IORING_ENTER_GETEVENTS | IORING_ENTER_EXT_ARG);
    printf("  arg.ts=%p (points to ts)\n", (void*)arg.ts);
    printf("  arg.sigmask=%llu\n", (unsigned long long)arg.sigmask);
    printf("  arg.sigmask_sz=%u\n", arg.sigmask_sz);
    printf("  argsz=%zu\n", sizeof(arg));
    printf("  ts.tv_sec=%lld, ts.tv_nsec=%lld\n", (long long)ts.tv_sec, (long long)ts.tv_nsec);

    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    long ret = syscall(__NR_io_uring_enter,
                      ring_fd,
                      0,  // to_submit
                      0,  // min_complete
                      IORING_ENTER_GETEVENTS | IORING_ENTER_EXT_ARG,
                      &arg,
                      sizeof(arg));

    clock_gettime(CLOCK_MONOTONIC, &end);

    if (ret < 0) {
        printf("io_uring_enter failed: ret=%ld, errno=%d (%s)\n", ret, errno, strerror(errno));
        close(ring_fd);
        return 1;
    }

    long elapsed_ms = (end.tv_sec - start.tv_sec) * 1000 +
                      (end.tv_nsec - start.tv_nsec) / 1000000;

    printf("Success! ret=%ld, elapsed=%ldms\n", ret, elapsed_ms);

    close(ring_fd);
    return 0;
}
