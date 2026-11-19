// SPDX-License-Identifier: MIT
// A wasm plugin's call stopped from outside (src/wasm_plugin.zig's deadline): the terminate flag
// of WAMR's execution environment, which compiled code with shared memory checks at every loop
// and call (wamrc --enable-multi-thread). An atomic OR: safe in a signal handler. Through WAMR's
// own headers, the flag's place in its WASMExecEnv is the pinned version's.
#include "wasm_export.h"
#include "wasm_exec_env.h"
#include "wasm_suspend_flags.h"

void det_wasm_interrupt(wasm_exec_env_t env) {
    WASM_SUSPEND_FLAGS_FETCH_OR(((WASMExecEnv *)env)->suspend_flags, WASM_SUSPEND_FLAG_TERMINATE);
}

void det_wasm_interrupt_clear(wasm_exec_env_t env) {
    WASM_SUSPEND_FLAGS_FETCH_AND(((WASMExecEnv *)env)->suspend_flags, ~WASM_SUSPEND_FLAG_TERMINATE);
}
