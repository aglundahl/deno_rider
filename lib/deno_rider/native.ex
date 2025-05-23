defmodule DenoRider.Native do
  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    base_url: "https://github.com/aglundahl/deno_rider/releases/download/v#{version}",
    crate: "deno_rider",
    force_build: System.get_env("DENO_RIDER_BUILD") == "true",
    nif_versions: ["2.15"],
    otp_app: :deno_rider,
    targets: [
      "aarch64-apple-darwin",
      "aarch64-unknown-linux-gnu",
      "x86_64-apple-darwin",
      "x86_64-pc-windows-msvc",
      "x86_64-unknown-linux-gnu"
    ],
    version: version

  def start_runtime(_pid, _main_module_path), do: :erlang.nif_error(:nif_not_loaded)

  def stop_runtime(_reference), do: :erlang.nif_error(:nif_not_loaded)

  def eval(_from, _reference, _code), do: :erlang.nif_error(:nif_not_loaded)

  def eval_blocking(_reference, _code), do: :erlang.nif_error(:nif_not_loaded)

  def apply_reply(_reference, _application_id, _result), do: :erlang.nif_error(:nif_not_loaded)
end
