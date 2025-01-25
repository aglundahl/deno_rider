use rustler::{Encoder, LocalPid, OwnedEnv};

pub fn send_to_pid<T>(pid: &LocalPid, data: T)
where
    T: Encoder,
{
    let _ = OwnedEnv::new().send_and_clear(pid, |_env| data);
}
