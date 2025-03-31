use slab::Slab;
use std::sync::{Mutex, OnceLock};

pub fn get() -> &'static Mutex<Slab<rustler::LocalPid>> {
    static RUNTIMES: OnceLock<Mutex<Slab<rustler::LocalPid>>> = OnceLock::new();
    RUNTIMES.get_or_init(|| Mutex::new(Slab::new()))
}
