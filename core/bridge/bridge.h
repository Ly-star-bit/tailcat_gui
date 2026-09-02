/*
 * Tailcat GUI core - C ABI.
 *
 * The library is a JSON command/event pipe around the Go engine.
 * Every char* returned by tc_call / tc_poll is heap-allocated and MUST be
 * released with tc_free. Strings are UTF-8, NUL-terminated.
 *
 * Threading: all functions may be called from any thread. tc_call blocks only
 * for short synchronous commands (parse_token, list_sessions, stop, ping,
 * list_remote); start_* commands return immediately with a session_id and
 * report progress through tc_poll events.
 */
#ifndef TAILCAT_CORE_BRIDGE_H
#define TAILCAT_CORE_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Initialise the engine. config_json may be NULL or "{}".
 * Recognised keys: "data_dir" (string), "derpmap_url" (string).
 * Returns 0 on success, non-zero on invalid config. Idempotent. */
int tc_init(const char* config_json);

/* Run one JSON request {"op": "...", "args": {...}} and return the JSON
 * response {"ok": true, "result": {...}} or {"ok": false, "error": {...}}. */
char* tc_call(const char* request_json);

/* Drain queued events: {"events": [...]}. Never NULL. */
char* tc_poll(void);

/* Free a string returned by tc_call or tc_poll. NULL is ignored. */
void tc_free(char* p);

/* Static version string "core/<version> tailcat/<version>". Do not free. */
const char* tc_version(void);

/* Stop every session and release the engine. tc_init may be called again. */
void tc_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif /* TAILCAT_CORE_BRIDGE_H */
