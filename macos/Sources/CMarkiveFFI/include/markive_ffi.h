#ifndef MARKIVE_FFI_H
#define MARKIVE_FFI_H

// C ABI over markive-core (crates/markive-ffi). Every char* returned is
// owned by the caller and must be released with mk_string_free.

// Renders NUL-terminated UTF-8 Markdown to sanitized HTML. base_dir may be
// NULL; when set it resolves relative image paths. Returns NULL on invalid
// UTF-8 input.
char *mk_render_document(const char *markdown, const char *base_dir);

// Releases a string returned by this library. NULL is a no-op.
void mk_string_free(char *ptr);

#endif
