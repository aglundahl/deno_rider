use crate::atoms;
use crate::error::Error;
use deno_runtime::worker::MainWorker;
use tokio::sync::oneshot::Sender;

pub enum Message {
    Execute(String, Sender<Result<String, Error>>),
    Stop(Sender<()>),
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
) {
    let mut poll_worker = true;
    loop {
        tokio::select! {
            Some(message) = worker_receiver.recv() => {
                match message {
                    Message::Stop(response_sender) => {
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
