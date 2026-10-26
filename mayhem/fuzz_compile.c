// libFuzzer harness: the full Gravity compiler front to back (lexer, parser, two semantic
// passes, IR, optimizer, bytecode) on arbitrary source text. Nothing is executed.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "gravity_compiler.h"
#include "gravity_core.h"

static void quiet_error (gravity_vm *vm, error_type_t type, const char *message, error_desc_t desc, void *xdata) {
    (void)vm; (void)type; (void)message; (void)desc; (void)xdata;
}

int LLVMFuzzerTestOneInput (const uint8_t *data, size_t size) {
    if (size == 0) return -1;

    // the CLI reads sources with file_read(), which NUL terminates the buffer
    char *source = (char *)malloc(size + 1);
    if (!source) return -1;
    memcpy(source, data, size);
    source[size] = 0;

    gravity_delegate_t delegate = {.error_callback = quiet_error};
    gravity_compiler_t *compiler = gravity_compiler_create(&delegate);
    gravity_closure_t *closure = gravity_compiler_run(compiler, source, size, 0, true, true);
    gravity_compiler_free(compiler);
    free(source);

    return closure ? 0 : -1;
}
