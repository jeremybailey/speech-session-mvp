#include <stdint.h>
#include <stddef.h>
void *cc_zip_open(const char *path);
int cc_zip_close(void *archive);
int cc_zip_first(void *archive);
int cc_zip_next(void *archive);
int cc_zip_info(void *archive, char *name, uint32_t capacity, uint64_t *size, uint32_t *attributes, uint16_t *flags, uint16_t *method);
int cc_zip_read_open(void *archive, const char *password);
int cc_zip_read(void *archive, void *buffer, uint32_t capacity);
int cc_zip_read_close(void *archive);
