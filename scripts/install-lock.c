// Keeps the install lock in the parent, so child tools cannot inherit it.
// The CLI uses a shared lock on the same file before starting a service.
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t child_pid = 0;
static void forward_signal(int signal_number) {
    if (child_pid > 0) kill((pid_t)child_pid, signal_number);
}

int main(int argc, char **argv) {
    if (argc < 5 || strcmp(argv[1], "--lock") != 0 || strcmp(argv[3], "--") != 0 || argv[2][0] == '\0') {
        fprintf(stderr, "Usage: workboard-install-lock --lock PATH -- COMMAND [ARGS...]\n");
        return 2;
    }
    int descriptor = open(argv[2], O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat info;
    if (descriptor < 0 || fstat(descriptor, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != getuid()) {
        fprintf(stderr, "Could not verify the installation lock file’s owner and type.\n");
        if (descriptor >= 0) close(descriptor);
        return 1;
    }
    if (fchmod(descriptor, 0600) != 0) { perror("install.lock permissions"); close(descriptor); return 1; }
    int locked = 0;
    for (int attempt = 0; attempt < 300; ++attempt) {
        if (flock(descriptor, LOCK_EX | LOCK_NB) == 0) { locked = 1; break; }
        if (errno != EWOULDBLOCK && errno != EAGAIN && errno != EINTR) break;
        usleep(100000);
    }
    if (!locked) {
        fprintf(stderr, "Another installation or service startup is in progress. Try again shortly.\n");
        close(descriptor);
        return 1;
    }
    struct sigaction action = {0};
    action.sa_handler = forward_signal;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGHUP, &action, NULL);
    pid_t child = fork();
    if (child < 0) { perror("fork"); close(descriptor); return 1; }
    if (child == 0) {
        close(descriptor);
        execvp(argv[4], &argv[4]);
        perror("install command");
        _exit(127);
    }
    child_pid = child;
    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) { perror("waitpid"); close(descriptor); return 1; }
    }
    flock(descriptor, LOCK_UN);
    close(descriptor);
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 1;
}
