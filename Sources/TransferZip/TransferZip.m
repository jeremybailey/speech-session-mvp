#import "TransferZip.h"
#import "ZipArchive.h"

// Narrow streaming adapter to the minizip compatibility API bundled in pinned
// ZipArchive 2.6.0. Public SSZipArchive unzip callbacks cannot limit bytes mid-file.
extern void *unzOpen64(const void *path);
extern int unzClose(void *file);
extern int unzGoToFirstFile(void *file);
extern int unzGoToNextFile(void *file);
extern int unzGetCurrentFileInfo64(void *, unz_file_info64 *, char *, unsigned long, void *, unsigned long, char *, unsigned long);
extern int unzOpenCurrentFilePassword(void *, const char *);
extern int unzReadCurrentFile(void *, void *, uint32_t);
extern int unzCloseCurrentFile(void *);

void *cc_zip_open(const char *path) { return unzOpen64(path); }
int cc_zip_close(void *a) { return unzClose(a); }
int cc_zip_first(void *a) { return unzGoToFirstFile(a); }
int cc_zip_next(void *a) { return unzGoToNextFile(a); }
int cc_zip_info(void *a, char *name, uint32_t cap, uint64_t *size, uint32_t *attr, uint16_t *flags, uint16_t *method) {
    unz_file_info64 info = {0};
    int result = unzGetCurrentFileInfo64(a, &info, name, cap, NULL, 0, NULL, 0);
    if (result != 0 || info.size_filename == 0 || info.size_filename >= cap) return -1;
    // Reject embedded NULs rather than interpreting a different path than the ZIP.
    for (uint16_t i = 0; i < info.size_filename; i++) if (name[i] == 0) return -1;
    name[info.size_filename] = 0;
    *size = info.uncompressed_size; *attr = info.external_fa; *flags = info.flag; *method = info.compression_method;
    // minizip reports the *actual* compression method, not ZIP's AES sentinel.
    // Check the AES extra field, including AE vendor and 256-bit strength.
    uint8_t *extra = calloc(info.size_file_extra, 1);
    if (!extra) return -1;
    result = unzGetCurrentFileInfo64(a, NULL, NULL, 0, extra, info.size_file_extra, NULL, 0);
    if (result == 0) {
        for (size_t offset = 0; offset + 4 <= info.size_file_extra;) {
            uint16_t type = extra[offset] | (extra[offset + 1] << 8);
            uint16_t length = extra[offset + 2] | (extra[offset + 3] << 8);
            offset += 4;
            if (offset + length > info.size_file_extra) { result = -1; break; }
            if (type == 0x9901 && length == 7 && extra[offset + 2] == 'A' && extra[offset + 3] == 'E' && extra[offset + 4] == 3)
                *method = 99;
            offset += length;
        }
    }
    free(extra);
    if (result != 0) return -1;
    return 0;
}
int cc_zip_read_open(void *a, const char *p) { return unzOpenCurrentFilePassword(a, p); }
int cc_zip_read(void *a, void *b, uint32_t n) { return unzReadCurrentFile(a, b, n); }
int cc_zip_read_close(void *a) { return unzCloseCurrentFile(a); }
