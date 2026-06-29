#ifndef ANKICORE_H
#define ANKICORE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A byte buffer returned across the FFI boundary.
 * When is_error is true, the bytes encode a backend error protobuf. */
typedef struct {
    uint8_t *ptr;
    size_t len;
    bool is_error;
} AnkiBytes;

/* Build hash of the linked Anki core. Free with anki_free_cstring. */
char *anki_buildhash(void);
void anki_free_cstring(char *ptr);

/* Backend lifecycle. init is a protobuf-encoded BackendInit (NULL/0 = defaults). */
void *anki_open_backend(const uint8_t *ptr, size_t len);
void anki_close_backend(void *backend);

/* Protobuf service dispatch (service/method are the generated indices). */
AnkiBytes anki_run_command(void *backend, uint32_t service, uint32_t method,
                           const uint8_t *ptr, size_t len);
AnkiBytes anki_run_db_command(void *backend, const uint8_t *ptr, size_t len);
void anki_free_bytes(AnkiBytes bytes);

#ifdef __cplusplus
}
#endif

#endif /* ANKICORE_H */
