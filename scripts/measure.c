// Traffic-only resource sampler. No task_for_pid privilege or system changes.
#include <libproc.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>

static double monotonic(void) {
    struct timespec time; clock_gettime(CLOCK_MONOTONIC, &time);
    return time.tv_sec + time.tv_nsec / 1e9;
}
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: measure PID seconds [interval] [warmup]\n"); return 2; }
    int pid = atoi(argv[1]), seconds = atoi(argv[2]);
    int interval = argc > 3 ? atoi(argv[3]) : 10;
    int warmup = argc > 4 ? atoi(argv[4]) : 20;
    if (pid <= 0 || seconds < 1 || interval < 1 || warmup < 0) return 2;
    sleep(warmup);
    struct rusage_info_v4 first = {0}, info = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&first)) { perror("proc_pid_rusage"); return 1; }
    double start = monotonic();
    puts("elapsed_seconds,cpu_percent_one_core,physical_footprint_bytes,resident_bytes,interrupt_wakes_delta,package_idle_wakes_delta,disk_read_bytes_delta,disk_write_bytes_delta");
    while (1) {
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&info)) { perror("proc_pid_rusage"); return 1; }
        double elapsed = monotonic() - start;
        double cpu = elapsed > .001 ? (info.ri_user_time - first.ri_user_time + info.ri_system_time - first.ri_system_time) / 1e9 / elapsed * 100 : 0;
        printf("%.3f,%.5f,%llu,%llu,%llu,%llu,%llu,%llu\n", elapsed, cpu,
            info.ri_phys_footprint, info.ri_resident_size,
            info.ri_interrupt_wkups - first.ri_interrupt_wkups, info.ri_pkg_idle_wkups - first.ri_pkg_idle_wkups,
            info.ri_diskio_bytesread - first.ri_diskio_bytesread, info.ri_diskio_byteswritten - first.ri_diskio_byteswritten);
        fflush(stdout);
        if (elapsed >= seconds) break;
        sleep(interval);
    }
}
