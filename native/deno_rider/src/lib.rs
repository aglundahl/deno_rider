mod atoms;
mod error;
mod runtime;
mod tokio_runtime;
mod util;
mod worker;

use rustler::Env;
use rustler::ResourceArc;

#[rustler::nif]
fn start_runtime(env: Env, main_module_path: String) -> rustler::Atom {
    let pid = env.pid();
    let (worker_sender, worker_receiver) =
        tokio::sync::mpsc::unbounded_channel::<worker::Message>();
    std::thread::spawn(move || {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                match worker::new(main_module_path).await {
                    Ok(worker) => {
                        util::send_to_pid(
                            &pid,
                            (
                                atoms::ok(),
                                ResourceArc::new(runtime::Runtime { worker_sender }),
                            ),
                        );
                        worker::run(worker, worker_receiver).await;
                    }
                    Err(message) => {
                        util::send_to_pid(&pid, (atoms::error(), message));
                    }
                }
            });
    });
    atoms::ok()
}

#[rustler::nif]
fn stop_runtime(env: Env, resource: ResourceArc<runtime::Runtime>) -> rustler::Atom {
    let pid = env.pid();
    let worker_sender = resource.worker_sender.clone();
    tokio_runtime::get().spawn(async move {
        let (response_sender, response_receiver) = tokio::sync::oneshot::channel();
        if worker_sender
            .send(worker::Message::Stop(response_sender))
            .is_ok()
        {
            response_receiver.await.unwrap();
            util::send_to_pid(&pid, atoms::ok());
        } else {
            util::send_to_pid(
                &pid,
                (
                    atoms::error(),
                    error::Error {
                        message: None,
                        name: atoms::dead_runtime_error(),
                    },
                ),
            );
        };
    });
    atoms::ok()
}

#[rustler::nif]
fn eval(
    env: Env,
    from: rustler::Term,
    resource: ResourceArc<runtime::Runtime>,
    message: String,
) -> rustler::Atom {
    let pid = env.pid();
    let worker_sender = resource.worker_sender.clone();
    let mut from_env = rustler::OwnedEnv::new();
    let saved_from = from_env.save(from);
    tokio_runtime::get().spawn(async move {
        let (response_sender, response_receiver) = tokio::sync::oneshot::channel();
        let result = if worker_sender
            .send(worker::Message::Execute(message, response_sender))
            .is_ok()
        {
            match response_receiver.await {
                Ok(result) => result,
                Err(_) => Err(error::Error {
                    message: None,
                    name: atoms::execution_error(),
                }),
            }
        } else {
            Err(error::Error {
                message: None,
                name: atoms::dead_runtime_error(),
            })
        };
        let _ = from_env.send_and_clear(&pid, |env| {
            (atoms::eval_reply(), saved_from.load(env), result)
        });
    });
    atoms::ok()
}

#[rustler::nif]
fn eval_blocking(
    resource: ResourceArc<runtime::Runtime>,
    message: String,
) -> Result<String, error::Error> {
    let (response_sender, response_receiver) = tokio::sync::oneshot::channel();
    resource
        .worker_sender
        .send(worker::Message::Execute(message, response_sender))
        .or(Err(error::Error {
            message: None,
            name: atoms::dead_runtime_error(),
        }))?;
    match response_receiver.blocking_recv() {
        Ok(result) => result,
        Err(_) => Err(error::Error {
            message: None,
            name: atoms::execution_error(),
        }),
    }
}

rustler::init!("Elixir.DenoRider.Native");
