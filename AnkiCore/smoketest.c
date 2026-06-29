/* Host-side smoke test for the C-ABI bridge (not shipped). */
#include <stdio.h>
#include "ankicore.h"

int main(void) {
    char *hash = anki_buildhash();
    printf("buildhash: %s\n", hash ? hash : "(null)");
    anki_free_cstring(hash);

    void *backend = anki_open_backend(NULL, 0);
    if (!backend) {
        printf("backend open FAILED\n");
        return 1;
    }
    printf("backend opened OK\n");
    anki_close_backend(backend);

    printf("FFI_SMOKE_OK\n");
    return 0;
}
