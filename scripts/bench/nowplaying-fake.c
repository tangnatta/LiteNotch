// Stand-in for macos/NowPlayingHelper used by scripts/bench.sh: reports one
// playing track, then waits until LiteNotch exits. Same entry points.
#include <stdio.h>
#include <unistd.h>

__attribute__((visibility("default"))) void ln_np_stream(void) {
    printf("{\"title\":\"Benchmark track\",\"artist\":\"LiteNotch\",\"app\":\"Music\","
           "\"playing\":true,\"duration_ms\":600000,\"elapsed_ms\":1000}\n");
    fflush(stdout);
    while (getppid() != 1) sleep(1);
}

__attribute__((visibility("default"))) void ln_np_send(void) {}
