use crate::atoms;
use crate::error::Error;
use crate::runtimes;
use crate::util;
use deno_core::op2;
use deno_runtime::worker::MainWorker;
use tokio::sync::oneshot::Sender;

pub enum Message {
    ApplyReply(String, Result<String, String>),
    Eval(String, Sender<Result<String, Error>>),
    Stop(Sender<()>),
}

#[op2(fast)]
fn op_apply(
    #[string] runtime_id: String,
    #[string] application_id: String,
    #[string] module: String,
    #[string] function_name: String,
    #[string] args: String,
) -> () {
    util::send_to_pid(
        runtimes::get()
            .lock()
            .unwrap()
            .get(runtime_id.parse::<usize>().unwrap())
            .unwrap(),
        (atoms::apply(), application_id, module, function_name, args),
    );
}

deno_core::extension!(
    extension,
    ops = [op_apply],
    esm_entry_point = "ext:extension/main.js",
    esm = [dir "extension", "main.js"]
);

pub async fn new(runtime_id: usize, main_module_path: String) -> Result<MainWorker, Error> {
    let path = std::env::current_dir().unwrap().join(main_module_path);
    let main_module = deno_core::ModuleSpecifier::from_file_path(path).unwrap();
    let mut worker = MainWorker::bootstrap_from_options(
        &main_module,
        deno_runtime::worker::WorkerServiceOptions::<
            deno_resolver::npm::DenoInNpmPackageChecker,
            deno_resolver::npm::NpmResolver<sys_traits::impls::RealSys>,
            sys_traits::impls::RealSys,
        > {
            blob_store: Default::default(),
            broadcast_channel: Default::default(),
            compiled_wasm_module_store: Default::default(),
            feature_checker: Default::default(),
            fetch_dns_resolver: Default::default(),
            fs: std::sync::Arc::new(deno_fs::RealFs),
            module_loader: std::rc::Rc::new(deno_core::FsModuleLoader),
            node_services: Default::default(),
            npm_process_state_provider: Default::default(),
            permissions: deno_runtime::deno_permissions::PermissionsContainer::allow_all(
                std::sync::Arc::new(
                    deno_runtime::permissions::RuntimePermissionDescriptorParser::new(
                        sys_traits::impls::RealSys,
                    ),
                ),
            ),
            root_cert_store_provider: Default::default(),
            shared_array_buffer_store: Default::default(),
            v8_code_cache: Default::default(),
        },
        deno_runtime::worker::WorkerOptions {
            extensions: vec![extension::init_ops_and_esm()],
            ..Default::default()
        },
    );
    worker
        .execute_script(
            "<anon>",
            format!("DenoRider._runtimeId = \"{}\"", runtime_id.to_string())
                .to_string()
                .into(),
        )
        .unwrap();
    worker
        .execute_main_module(&main_module)
        .await
        .map_err(|error| Error {
            message: Some(error.to_string()),
            name: atoms::execution_error(),
            value: None,
        })?;
    Ok(worker)
}

pub async fn run(
    runtime_id: usize,
    mut worker: MainWorker,
    mut worker_receiver: tokio::sync::mpsc::UnboundedReceiver<Message>,
) {
    let mut promises = slab::Slab::new();
    let mut poll_event_loop = true;
    loop {
        tokio::select! {
            Some(message) = worker_receiver.recv() => {
                match message {
                    Message::Stop(response_sender) => {
                        worker_receiver.close();
                        response_sender.send(()).unwrap();
                        runtimes::get().lock().unwrap().remove(runtime_id);
                        break;
                    },
                    Message::ApplyReply(application_id, result) => {
                        let (function, value) = match result {
                            Ok(value) => { ("resolve", value) },
                            Err(value) => { ("reject", value) }
                        };
                        worker.execute_script(
                            "<anon>",
                            format!("DenoRider._applications[\"{application_id}\"].{function}({value})").to_string().into()
                        ).unwrap();
                        poll_event_loop = true;
                    },
                    Message::Eval(code, response_sender) => {
                        match worker.execute_script("<anon>", code.into()) {
                            Ok(global) => {
                                if {
                                    let scope = &mut worker.js_runtime.handle_scope();
                                    let local = deno_core::v8::Local::new(scope, &global);
                                    local.is_promise()
                                } {
                                    promises.insert((global, response_sender));
                                } else {
                                    let scope = &mut worker.js_runtime.handle_scope();
                                    let local = deno_core::v8::Local::new(scope, &global);
                                    match serde_v8::from_v8::<serde_json::Value>(scope, local) {
                                        Ok(value) => {
                                            response_sender.send(Ok(value.to_string())).unwrap();
                                        },
                                        Err(_) => {
                                            response_sender.send(
                                                Err(
                                                    Error {
                                                        message: None,
                                                        name: atoms::conversion_error(),
                                                        value: None
                                                    }
                                                )
                                            ).unwrap();
                                        }
                                    }
                                }
                            },
                            Err(error) => {
                                response_sender.send(
                                    Err(
                                        Error {
                                            message: Some(error.to_string()),
                                            name: atoms::execution_error(),
                                            value: None
                                        }
                                    )
                                ).unwrap();
                            }
                        };
                        poll_event_loop = true;
                    }
                }
            },
            _ = run_event_loop(&mut worker, &mut promises), if poll_event_loop => {
                poll_event_loop = false;
            },
            else => {
                break;
            }
        }
    }
}

async fn run_event_loop(
    worker: &mut MainWorker,
    promises: &mut slab::Slab<(
        deno_core::v8::Global<deno_core::v8::Value>,
        Sender<Result<String, Error>>,
    )>,
) -> Result<(), deno_core::error::CoreError> {
    std::future::poll_fn(|cx| {
        let poll = worker.js_runtime.poll_event_loop(cx, Default::default());
        let scope = &mut worker.js_runtime.handle_scope();
        let resolved_promises: Vec<_> = promises
            .iter()
            .filter_map(|(key, (global, _))| {
                let local = deno_core::v8::Local::new(scope, global);
                let promise =
                    deno_core::v8::Local::<deno_core::v8::Promise>::try_from(local).unwrap();
                if matches!(
                    promise.state(),
                    deno_core::v8::PromiseState::Fulfilled | deno_core::v8::PromiseState::Rejected
                ) {
                    Some(key)
                } else {
                    None
                }
            })
            .collect();
        for promise_key in resolved_promises {
            let (global, response_sender) = promises.remove(promise_key);
            let local = deno_core::v8::Local::new(scope, global);
            let promise = deno_core::v8::Local::<deno_core::v8::Promise>::try_from(local).unwrap();
            let result = promise.result(scope);
            match serde_v8::from_v8::<serde_json::Value>(scope, result) {
                Ok(value) => {
                    if promise.state() == deno_core::v8::PromiseState::Fulfilled {
                        response_sender.send(Ok(value.to_string())).unwrap();
                    } else {
                        response_sender
                            .send(Err(Error {
                                message: None,
                                name: atoms::promise_rejection(),
                                value: Some(value.to_string()),
                            }))
                            .unwrap();
                    }
                }
                Err(_) => {
                    response_sender
                        .send(Err(Error {
                            message: None,
                            name: atoms::conversion_error(),
                            value: None,
                        }))
                        .unwrap();
                }
            }
        }
        return poll;
    })
    .await
}
