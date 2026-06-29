// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// C-ABI shim over Anki's Rust core, mirroring pylib/rsbridge/lib.rs but for
// Swift/iOS. The entire backend API funnels through `run_service_method`
// (protobuf in, protobuf out); everything else is a thin wrapper.

use std::ffi::CString;
use std::os::raw::c_char;
use std::os::raw::c_void;
use std::slice;

use anki::backend::init_backend;
use anki::backend::Backend;

/// A byte buffer handed across the FFI boundary. `is_error` is true when the
/// bytes encode a backend error protobuf instead of a normal response.
#[repr(C)]
pub struct AnkiBytes {
    ptr: *mut u8,
    len: usize,
    is_error: bool,
}

impl AnkiBytes {
    fn from_vec(v: Vec<u8>, is_error: bool) -> Self {
        let mut boxed = v.into_boxed_slice();
        let ptr = boxed.as_mut_ptr();
        let len = boxed.len();
        std::mem::forget(boxed);
        AnkiBytes { ptr, len, is_error }
    }

    fn empty(is_error: bool) -> Self {
        AnkiBytes {
            ptr: std::ptr::null_mut(),
            len: 0,
            is_error,
        }
    }
}

fn slice_from_raw<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(ptr, len) }
    }
}

/// Returns the build hash of the linked Anki core. Free with `anki_free_cstring`.
#[no_mangle]
pub extern "C" fn anki_buildhash() -> *mut c_char {
    CString::new(anki::version::buildhash())
        .unwrap_or_default()
        .into_raw()
}

#[no_mangle]
pub extern "C" fn anki_free_cstring(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}

/// Creates a backend from a protobuf-encoded `BackendInit`. Pass a null/empty
/// buffer for defaults. Returns null on failure. Free with `anki_close_backend`.
#[no_mangle]
pub extern "C" fn anki_open_backend(ptr: *const u8, len: usize) -> *mut c_void {
    let init = slice_from_raw(ptr, len);
    match init_backend(init) {
        Ok(backend) => Box::into_raw(Box::new(backend)) as *mut c_void,
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn anki_close_backend(backend: *mut c_void) {
    if !backend.is_null() {
        unsafe {
            drop(Box::from_raw(backend as *mut Backend));
        }
    }
}

/// Runs a protobuf service method. `service`/`method` are the generated indices.
#[no_mangle]
pub extern "C" fn anki_run_command(
    backend: *mut c_void,
    service: u32,
    method: u32,
    ptr: *const u8,
    len: usize,
) -> AnkiBytes {
    if backend.is_null() {
        return AnkiBytes::empty(true);
    }
    let backend = unsafe { &*(backend as *mut Backend) };
    let input = slice_from_raw(ptr, len);
    match backend.run_service_method(service, method, input) {
        Ok(out) => AnkiBytes::from_vec(out, false),
        Err(err) => AnkiBytes::from_vec(err, true),
    }
}

/// Runs a DB command (JSON in/out), mirroring rsbridge's `db_command`.
#[no_mangle]
pub extern "C" fn anki_run_db_command(
    backend: *mut c_void,
    ptr: *const u8,
    len: usize,
) -> AnkiBytes {
    if backend.is_null() {
        return AnkiBytes::empty(true);
    }
    let backend = unsafe { &*(backend as *mut Backend) };
    let input = slice_from_raw(ptr, len);
    match backend.run_db_command_bytes(input) {
        Ok(out) => AnkiBytes::from_vec(out, false),
        Err(err) => AnkiBytes::from_vec(err, true),
    }
}

#[no_mangle]
pub extern "C" fn anki_free_bytes(bytes: AnkiBytes) {
    if !bytes.ptr.is_null() {
        unsafe {
            let _ = Vec::from_raw_parts(bytes.ptr, bytes.len, bytes.len);
        }
    }
}
