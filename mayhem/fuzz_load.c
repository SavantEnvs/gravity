// libFuzzer harness: the JSON executable loader behind `gravity -x` (json_parse plus
// object deserialization). The buffer is passed exactly sized and NOT NUL terminated,
// which is what gravity_vm_loadbuffer() is documented to accept.
#include <stdint.h>
#include "gravity_vm.h"
#include "gravity_core.h"

static void quiet_error (gravity_vm *vm, error_type_t type, const char *message, error_desc_t desc, void *xdata) {
    (void)vm; (void)type; (void)message; (void)desc; (void)xdata;
}

int LLVMFuzzerTestOneInput (const uint8_t *data, size_t size) {
    if (size == 0) return -1;

    gravity_delegate_t delegate = {.error_callback = quiet_error};
    gravity_vm *vm = gravity_vm_new(&delegate);
    gravity_closure_t *closure = gravity_vm_loadbuffer(vm, (const char *)data, size);
    gravity_vm_free(vm);
    gravity_core_free();

    return closure ? 0 : -1;
}
