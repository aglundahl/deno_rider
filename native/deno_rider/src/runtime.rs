use crate::worker;

pub struct Runtime {
    pub worker_sender: tokio::sync::mpsc::UnboundedSender<worker::Message>,
    /// Thread-safe handle to the runtime's V8 isolate. It is the only way to stop JavaScript
    /// that is already running: the worker thread is inside `execute_script` and reads no
    /// channel message until the script returns, which `while (true) {}` never does.
    pub isolate_handle: deno_core::v8::IsolateHandle,
}

#[rustler::resource_impl]
impl rustler::Resource for Runtime {}

/// Stops the JavaScript that the runtime is running when the owning process goes away, for
/// example when it is killed after an eval timeout. Without it, a script that never returns
/// keeps its worker thread and isolate alive for the life of the VM.
impl Drop for Runtime {
    fn drop(&mut self) {
        self.isolate_handle.terminate_execution();
    }
}
