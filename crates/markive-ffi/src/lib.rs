//! C ABI over markive-core for the native macOS app.
//!
//! Contract: every `*mut c_char` returned by this crate is owned by the
//! caller and must be released with [`mk_string_free`]. Inputs must be
//! NUL-terminated UTF-8; invalid UTF-8 yields a null pointer.

// Every export here dereferences caller pointers by design; the safety
// contract lives in the header comments, not in `unsafe fn` signatures
// (extern "C" symbols are called from C, which has no unsafe keyword).
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use std::ffi::{CStr, CString, c_char};
use std::path::Path;

/// Renders Markdown to sanitized HTML. `base_dir` may be null; when set it
/// resolves relative image paths, matching `markive_core::render_document`.
/// Returns null on invalid UTF-8 input. Free the result with `mk_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn mk_render_document(
    markdown: *const c_char,
    base_dir: *const c_char,
) -> *mut c_char {
    if markdown.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(markdown) = (unsafe { CStr::from_ptr(markdown) }).to_str() else {
        return std::ptr::null_mut();
    };
    let base_dir = if base_dir.is_null() {
        None
    } else {
        (unsafe { CStr::from_ptr(base_dir) }).to_str().ok()
    };

    let rendered = markive_core::render_document(markdown, base_dir.map(Path::new));
    // Sanitized HTML cannot contain interior NULs; treat one as a bug, not UB.
    match CString::new(rendered.html().to_owned()) {
        Ok(html) => html.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// One editor highlight span: a half-open `[start, end)` byte range of
/// the UTF-8 source and a kind discriminant matching
/// `markive_core::SpanKind` (0 heading … 7 blockquote).
#[repr(C)]
pub struct MkSpan {
    pub start: u32,
    pub end: u32,
    pub kind: u8,
}

/// Extracts highlight spans from NUL-terminated UTF-8 Markdown. Writes
/// the span count to `out_len` and returns a caller-owned array to be
/// released with [`mk_spans_free`] using the same length. Returns null
/// (with `out_len` 0) on invalid input or when there are no spans.
#[unsafe(no_mangle)]
pub extern "C" fn mk_highlight_spans(
    markdown: *const c_char,
    out_len: *mut usize,
) -> *mut MkSpan {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    unsafe { *out_len = 0 };
    if markdown.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(markdown) = (unsafe { CStr::from_ptr(markdown) }).to_str() else {
        return std::ptr::null_mut();
    };

    let spans: Vec<MkSpan> = markive_core::highlight_spans(markdown)
        .into_iter()
        .map(|span| MkSpan {
            start: span.start,
            end: span.end,
            kind: span.kind as u8,
        })
        .collect();
    if spans.is_empty() {
        return std::ptr::null_mut();
    }

    let mut spans = spans.into_boxed_slice();
    unsafe { *out_len = spans.len() };
    let ptr = spans.as_mut_ptr();
    std::mem::forget(spans);
    ptr
}

/// Releases a span array returned by [`mk_highlight_spans`]. `len` must
/// be the value written to `out_len`. Null is a no-op.
#[unsafe(no_mangle)]
pub extern "C" fn mk_spans_free(ptr: *mut MkSpan, len: usize) {
    if !ptr.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) });
    }
}

/// Releases a string returned by this crate. Null is a no-op.
#[unsafe(no_mangle)]
pub extern "C" fn mk_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(unsafe { CString::from_raw(ptr) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn renders_and_frees() {
        let input = CString::new("# Hello\n\n*world*").unwrap();
        let out = mk_render_document(input.as_ptr(), std::ptr::null());
        assert!(!out.is_null());
        let html = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_owned();
        assert!(html.contains("<h1"));
        assert!(html.contains("<em>world</em>"));
        mk_string_free(out);
    }

    #[test]
    fn highlights_and_frees() {
        let input = CString::new("# Hi\n\n*em*").unwrap();
        let mut len = 0usize;
        let out = mk_highlight_spans(input.as_ptr(), &raw mut len);
        assert!(!out.is_null());
        assert_eq!(len, 2);
        let spans = unsafe { std::slice::from_raw_parts(out, len) };
        assert_eq!((spans[0].start, spans[0].end, spans[0].kind), (0, 5, 0));
        assert_eq!(spans[1].kind, 1);
        mk_spans_free(out, len);
    }

    #[test]
    fn empty_and_invalid_span_inputs_yield_null() {
        let mut len = 42usize;
        let empty = CString::new("").unwrap();
        assert!(mk_highlight_spans(empty.as_ptr(), &raw mut len).is_null());
        assert_eq!(len, 0);
        len = 42;
        assert!(mk_highlight_spans(std::ptr::null(), &raw mut len).is_null());
        assert_eq!(len, 0);
        mk_spans_free(std::ptr::null_mut(), 0);
    }

    #[test]
    fn null_and_invalid_inputs_yield_null() {
        assert!(mk_render_document(std::ptr::null(), std::ptr::null()).is_null());
        let invalid = [0xffu8, 0xfe, 0x00];
        assert!(
            mk_render_document(invalid.as_ptr().cast(), std::ptr::null()).is_null()
        );
        mk_string_free(std::ptr::null_mut());
    }
}
