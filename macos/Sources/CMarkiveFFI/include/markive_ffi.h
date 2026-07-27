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

#include <stddef.h>
#include <stdint.h>

// One editor highlight span: a half-open [start, end) byte range of the
// UTF-8 source. kind: 0 heading, 1 emphasis, 2 strong, 3 code span,
// 4 code block, 5 link, 6 list marker, 7 blockquote.
typedef struct {
    uint32_t start;
    uint32_t end;
    uint8_t kind;
} MkSpan;

// Extracts highlight spans from NUL-terminated UTF-8 Markdown. Writes the
// span count to out_len and returns a caller-owned array to release with
// mk_spans_free using the same length. Returns NULL (out_len 0) on
// invalid input or when there are no spans.
MkSpan *mk_highlight_spans(const char *markdown, size_t *out_len);

// Releases a span array returned by mk_highlight_spans. NULL is a no-op.
void mk_spans_free(MkSpan *ptr, size_t len);

#endif
