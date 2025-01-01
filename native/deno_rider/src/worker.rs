use crate::atoms;
use crate::error::Error;
use deno_runtime::worker::MainWorker;
use std::collections::HashMap;
use std::string::String;
use tokio::sync::oneshot::Sender;
struct IsolateInstance {
    isolate: deno_core::v8::OwnedIsolate,
    context: deno_core::v8::Global<deno_core::v8::Context>,
}

struct WorkerState {
    isolates: Vec<(String, IsolateInstance)>,
    isolate_map: HashMap<String, usize>,
}

pub enum Message {
    Execute(String, Sender<Result<String, Error>>),
    Stop(Sender<()>),
    CreateIsolate(String, Sender<Result<String, Error>>),
    ExecuteInIsolate(String, String, Sender<Result<String, Error>>),
    DisposeIsolate(String, Sender<Result<(), Error>>),
}

deno_core::extension!(
    extension,
    esm_entry_point = "ext:extension/main.js",
    esm = [dir "extension", "main.js"]
);

pub async fn new(main_module_path: String) -> Result<MainWorker, Error> {
    let path = std::env::current_dir().unwrap().join(main_module_path);
    let main_module = deno_core::ModuleSpecifier::from_file_path(path).unwrap();
    let fs = std::sync::Arc::new(deno_fs::RealFs);
    let descriptor_parser = std::sync::Arc::new(
        deno_runtime::permissions::RuntimePermissionDescriptorParser::new(fs.clone()),
    );
    let mut worker = MainWorker::bootstrap_from_options(
        main_module.clone(),
        deno_runtime::worker::WorkerServiceOptions {
            blob_store: Default::default(),
            broadcast_channel: Default::default(),
            compiled_wasm_module_store: Default::default(),
            feature_checker: Default::default(),
            fs,
            module_loader: std::rc::Rc::new(deno_core::FsModuleLoader),
            node_services: Default::default(),
            npm_process_state_provider: Default::default(),
            permissions: deno_runtime::deno_permissions::PermissionsContainer::allow_all(
                descriptor_parser,
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
        .execute_main_module(&main_module)
        .await
        .map_err(|error| Error {
            message: Some(error.to_string()),
            name: atoms::execution_error(),
        })?;
    Ok(worker)
}

pub async fn run(
    mut worker: MainWorker,
    mut worker_receiver: tokio::sync::mpsc::UnboundedReceiver<Message>,
) -> () {
    let mut state = WorkerState {
        isolates: Vec::new(),
        isolate_map: HashMap::new(),
    };
    let mut poll_worker = true;

    loop {
        tokio::select! {
            Some(message) = worker_receiver.recv() => {
                match message {
                    Message::CreateIsolate(isolate_id, response_sender) => {
                        let mut isolate = deno_core::v8::Isolate::new(Default::default());
                        let context = {
                            let mut handle_scope = deno_core::v8::HandleScope::new(&mut isolate);
                            let context = deno_core::v8::Context::new(&mut handle_scope, Default::default());
                            deno_core::v8::Global::new(&mut handle_scope, context)
                        };

                        state.isolates.push((isolate_id.clone(), IsolateInstance {
                            isolate,
                            context,
                        }));
                        state.isolate_map.insert(isolate_id.clone(), state.isolates.len() - 1);

                        response_sender.send(Ok(isolate_id)).unwrap();
                    },
                    Message::ExecuteInIsolate(isolate_id, code, response_sender) => {
                        if let Some(instance) = state.isolate_map.get(&isolate_id)
                            .and_then(|&idx| state.isolates.get_mut(idx))
                            .map(|(_, instance)| instance)
                        {
                            let result = execute_in_isolate(instance, &code);
                            response_sender.send(result).unwrap();
                        } else {
                            response_sender.send(Err(Error {
                                message: Some("Isolate not found".to_string()),
                                name: atoms::execution_error(),
                            })).unwrap();
                        }
                    },
                    Message::DisposeIsolate(isolate_id, response_sender) => {
                        if let Some(&idx) = state.isolate_map.get(&isolate_id) {
                            if idx == state.isolates.len() - 1 {
                                if let Some((_, instance)) = state.isolates.pop() {
                                    drop(instance.isolate);
                                    state.isolate_map.remove(&isolate_id);
                                    response_sender.send(Ok(())).unwrap();
                                }
                            } else {
                                let next_disposable = state.isolates.last()
                                    .map(|(id, _)| id.clone())
                                    .unwrap_or_default();
                                response_sender.send(Err(Error {
                                    message: Some(format!("Isolate {} must be disposed first", next_disposable)),
                                    name: atoms::execution_error(),
                                })).unwrap();
                            }
                        }
                    },
                    Message::Stop(response_sender) => {
                        while let Some((_, instance)) = state.isolates.pop() {
                            drop(instance.isolate);
                        }
                        worker_receiver.close();
                        response_sender.send(()).unwrap();
                        break;
                    },
                    Message::Execute(code, response_sender) => {
                        match worker.execute_script("<anon>", code.into()) {
                            Ok(global) => {
                                let scope = &mut worker.js_runtime.handle_scope();
                                let local = deno_core::v8::Local::new(scope, global);
                                match serde_v8::from_v8::<serde_json::Value>(scope, local) {
                                    Ok(value) => {
                                        response_sender.send(Ok(value.to_string())).unwrap();
                                    },
                                    Err(_) => {
                                        response_sender.send(
                                            Err(
                                                Error {
                                                    message: None,
                                                    name: atoms::conversion_error()
                                                }
                                            )
                                        ).unwrap();
                                    }
                                }
                            },
                            Err(error) => {
                                response_sender.send(
                                    Err(
                                        Error {
                                            message: Some(error.to_string()),
                                            name: atoms::execution_error()
                                        }
                                    )
                                ).unwrap();
                            }
                        };
                        poll_worker = true;
                    }
                }
            },
            _ = worker.run_event_loop(false), if poll_worker => {
                poll_worker = false;
            },
            else => {
                break;
            }
        }
    }
}

fn execute_in_isolate(instance: &mut IsolateInstance, code: &str) -> Result<String, Error> {
    let mut handle_scope = deno_core::v8::HandleScope::new(&mut instance.isolate);
    let context = deno_core::v8::Local::new(&mut handle_scope, &instance.context);
    let mut scope = deno_core::v8::ContextScope::new(&mut handle_scope, context);

    let code = deno_core::v8::String::new(&mut scope, code).ok_or_else(|| Error {
        message: Some("Failed to create V8 string".to_string()),
        name: atoms::execution_error(),
    })?;

    let script = deno_core::v8::Script::compile(&mut scope, code, None).ok_or_else(|| Error {
        message: Some("Failed to compile script".to_string()),
        name: atoms::execution_error(),
    })?;

    let result = script.run(&mut scope).ok_or_else(|| Error {
        message: Some("Failed to run script".to_string()),
        name: atoms::execution_error(),
    })?;

    let json: serde_json::Value = serde_v8::from_v8(&mut scope, result).map_err(|_| Error {
        message: None,
        name: atoms::conversion_error(),
    })?;

    Ok(json.to_string())
}
