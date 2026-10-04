#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char** argv) {
    if (argc < 2) return 99;
    if (!strcmp(argv[1], "--startup")) {
        kill(getppid(), SIGINT);
        usleep(20000);
        printf("cleanup\n");
        return 130;
    }
    if (argc != 3 || strcmp(argv[1], "--signal")) return 99;
    int signal = !strcmp(argv[2], "INT") ? SIGINT : SIGQUIT;
    struct sigaction action = {};
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    sigaction(signal, &action, NULL);
    kill(getppid(), signal);
    kill(getpid(), signal);
    return 99;
}
