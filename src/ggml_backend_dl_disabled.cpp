#include "ggml-backend-dl.h"

dl_handle * dl_load_library(const fs::path &) {
    return nullptr;
}

void * dl_get_sym(dl_handle *, const char *) {
    return nullptr;
}

const char * dl_error() {
    return "dynamic backend loading is disabled by Venera";
}
