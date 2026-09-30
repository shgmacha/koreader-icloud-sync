// Tiny launcher so macOS privacy permissions (Full Disk Access) can be granted
// to "KOReader iCloud Bridge.app" instead of a Python binary buried in Xcode.
//
// It spawns (not execs) the interpreter: a spawned child's file access is
// attributed to this app, so the app's Full Disk Access grant covers it.
//
// Usage: launcher <python> <script> [args...]
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static pid_t child = 0;

static void forward(int sig) {
    if (child > 0) kill(child, sig);
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <python> <script> [args...]\n", argv[0]);
        return 2;
    }
    signal(SIGTERM, forward);
    signal(SIGINT, forward);
    signal(SIGHUP, forward);

    int err = posix_spawn(&child, argv[1], NULL, NULL, &argv[1], environ);
    if (err != 0) {
        fprintf(stderr, "launcher: cannot start %s (error %d)\n", argv[1], err);
        return 1;
    }
    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        /* retry on EINTR (signal forwarded) */
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return 128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 0);
}
