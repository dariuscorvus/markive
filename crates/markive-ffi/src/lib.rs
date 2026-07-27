//! C ABI over markive-core for the native macOS app.
//!
//! Contract: every `*mut c_char` returned by this crate is owned by the
//! caller and must be released with [`mk_string_free`]. Inputs must be
//! NUL-terminated UTF-8; invalid UTF-8 yields a null pointer.

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
    fn null_and_invalid_inputs_yield_null() {
        assert!(mk_render_document(std::ptr::null(), std::ptr::null()).is_null());
        let invalid = [0xffu8, 0xfe, 0x00];
        assert!(
            mk_render_document(invalid.as_ptr().cast(), std::ptr::null()).is_null()
        );
        mk_string_free(std::ptr::null_mut());
    }
}
