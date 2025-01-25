use std::sync::OnceLock;

use tokio::runtime::{Builder, Runtime};

pub fn get() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();

    RUNTIME.get_or_init(|| Builder::new_multi_thread().enable_all().build().unwrap())
}
