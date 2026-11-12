// C interface of the LiteNotch core (crates/app/src/ffi.rs).
// Strings are UTF-8 and NUL-terminated.
#ifndef LITENOTCH_H
#define LITENOTCH_H

#include <stdbool.h>

// Receives the view model as JSON each time it changes. Called on the
// core's thread; `view_json` is valid only during the call.
typedef void (*ln_view_callback)(const char *view_json, void *context);

// Starts the core. `config_json`: {"home": "...", "cli_path": "...",
// "data_dir": "..." (optional)}. Returns false if the configuration is
// invalid, the core is already started, or another LiteNotch is running.
bool ln_start(const char *config_json, ln_view_callback callback, void *context);

// Sends one command, e.g. {"cmd":"pomodoro_toggle"}. Returns false if the
// command is malformed or the core is not running.
bool ln_send(const char *command_json);

// Stops the core: saves state, releases keep-awake, answers waiting hooks.
void ln_stop(void);

#endif
