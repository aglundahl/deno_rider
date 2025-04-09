defmodule DenoRider do
  use GenServer

  alias DenoRider.Error
  alias DenoRider.Native
  alias DenoRider.Runtime

  @doc """
  Start a DenoRider process without any main module.

  See `start/1` for more information.

  ## Examples

      iex> {:ok, pid} = DenoRider.start()
      iex> DenoRider.eval("1 + 2", pid: pid)
      {:ok, 3}
  """
  @spec start() :: GenServer.on_start()
  def start do
    start([])
  end

  @doc """
  Start a DenoRider process.

  ## Options

    * `:main_module_path` - Path to the main JavaScript module. The default is
      to start the runtime without a main module.

  ## Examples

      iex> DenoRider.start(main_module_path: "path/to/main.js")
  """
  @spec start() :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @doc """
  Same as `stop/1`, but it assumes that there is a process with the name
  `DenoRider` (the default if you don't provide a name to `start_link/1`).
  """
  @spec stop() :: :ok
  def stop do
    stop([])
  end

  @doc """
  Stop a DenoRider process.

  ## Options

    * `:name` - The name of the DenoRider process. The default is
      `DenoRider`. Can't be provided if `:pid` is provided.
    * `:pid` - The pid of the DenoRider process. Can't be provided if `:name` is
      provided.
    * `:reason` - See `GenServer.stop/3`.
    * `:timeout` - See `GenServer.stop/3`.

  ## Examples

      iex> {:ok, pid} = DenoRider.start()
      iex> DenoRider.stop(pid: pid)
      :ok
  """
  @spec stop(Keyword.t()) :: :ok
  def stop(opts) do
    GenServer.stop(
      Keyword.get(opts, :pid) || Keyword.get(opts, :name, __MODULE__),
      Keyword.get(opts, :reason, :normal),
      Keyword.get(opts, :timeout, :infinity)
    )
  end

  @doc """
  Start a DenoRider process linked to the current process.

  ## Options

    * `:name` - The name of the process. The default is `DenoRider`.

  See `start/1` for more options.

  ## Examples

      iex> DenoRider.start_link(name: MyApp.DenoRider)
      iex> DenoRider.eval("1 + 2", name: MyApp.DenoRider)
      {:ok, 3}
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(
      __MODULE__,
      Keyword.take(opts, [:main_module_path]),
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  @doc """
  Same as `eval/2`, but it assumes that there is a process with the name
  `DenoRider` (the default if you don't provide a name to `start_link/1`).

  ## Examples

      iex> DenoRider.eval("1 + 2")
      {:ok, 3}
  """
  @spec eval(binary()) :: {:ok, term()} | {:error, Error.t()}
  def eval(code) do
    eval(code, name: __MODULE__)
  end

  @doc """
  Run the given JavaScript code and return the result. If a promise is returned,
  it will be awaited.

  ## Options

    * `:blocking` - Indicates whether the NIF call should block until the
      JavaScript execution finishes or not. Blocking is more performant, but it
      can also cause problems if the call takes too long. The [NIF
      documentation](https://www.erlang.org/doc/apps/erts/erl_nif.html#lengthy_work)
      suggests that a NIF call shouldn't take more than 1 millisecond. Only set
      this to `true` if you need the performance boost and the execution stays
      below 1 millisecond or so. The default is `false`.
    * `:name` - The name of the DenoRider process. The default is
      `DenoRider`. Can't be provided if `:pid` is provided.
    * `:pid` - The pid of the DenoRider process. Can't be provided if `:name` is
      provided.
    * `:timeout` - The timeout for the eval, default is `5000`.

  ## Examples

      iex> DenoRider.eval("1 + 2")
      {:ok, 3}

      iex> DenoRider.eval("1 + 2", blocking: true)
      {:ok, 3}

      iex> DenoRider.start_link(name: :foo)
      iex> DenoRider.eval("1 + 2", name: :foo)
      {:ok, 3}

      iex> {:ok, pid} = DenoRider.start()
      iex> DenoRider.eval("1 + 2", pid: pid)
      {:ok, 3}
  """
  @spec eval(binary(), Keyword.t()) :: {:ok, term()} | {:error, Error.t()}
  def eval(code, opts) do
    GenServer.call(
      Keyword.get(opts, :pid) || Keyword.get(opts, :name, __MODULE__),
      {:eval, code, opts},
      Keyword.get(opts, :timeout, 5000)
    )
  end

  @doc """
  Same as `eval/1`, but raises if the result isn't successful.
  """
  @spec eval!(binary()) :: term()
  def eval!(code) do
    {:ok, result} = eval(code)
    result
  end

  @doc """
  Same as `eval/2`, but raises if the result isn't successful.
  """
  @spec eval!(binary(), Keyword.t()) :: term()
  def eval!(code, opts) do
    {:ok, result} = eval(code, opts)
    result
  end

  @impl GenServer
  def init(opts) do
    pid = self()

    result =
      Task.async(fn ->
        :ok =
          Native.start_runtime(
            pid,
            Keyword.get(
              opts,
              :main_module_path,
              "#{Application.app_dir(:deno_rider)}/priv/main.js"
            )
          )

        receive do
          {:ok, reference} ->
            {:ok, %Runtime{reference: reference}}

          error ->
            error
        end
      end)
      |> Task.await()

    case result do
      {:ok, _} = result ->
        result

      {:error, error} ->
        {:stop, error}
    end
  end

  @impl GenServer
  def handle_call({:eval, code, opts}, from, state) do
    if Keyword.get(opts, :blocking, false) do
      case Native.eval_blocking(state.reference, code) do
        {:ok, json} ->
          {:reply, {:ok, Jason.decode!(json)}, state}

        {:error, %Error{name: :dead_runtime_error}} ->
          {:stop, {:shutdown, :dead_runtime_error}, state}

        error ->
          {:reply, decode_promise_rejection(error), state}
      end
    else
      :ok = Native.eval(from, state.reference, code)
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:apply, application_id, module, function_name, args}, state) do
    decoded_args = Jason.decode!(args)

    result =
      with {:ok, decoded_module} <- to_module(module),
           {:ok, decoded_function_name} <- to_atom(function_name),
           :ok <-
             function_exists?(decoded_module, decoded_function_name, Enum.count(decoded_args)),
           result <- apply(decoded_module, decoded_function_name, decoded_args),
           {:ok, encoded_result} <- encode_json(result) do
        {:ok, encoded_result}
      else
        {:error, error} ->
          {:error, Jason.encode!(error)}
      end

    {:ok, {}} =
      Native.apply_reply(
        state.reference,
        application_id,
        result
      )

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:eval_reply, from, result}, state) do
    case result do
      {:ok, json} ->
        GenServer.reply(from, {:ok, Jason.decode!(json)})
        {:noreply, state}

      {:error, %Error{name: :dead_runtime_error}} ->
        {:stop, {:shutdown, :dead_runtime_error}, state}

      error ->
        GenServer.reply(from, decode_promise_rejection(error))
        {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_, state) do
    :ok = Native.stop_runtime(state.reference)
  end

  defp decode_promise_rejection(error) do
    case error do
      {:error, %Error{name: :promise_rejection} = e} ->
        {:error, %{e | value: Jason.decode!(e.value)}}

      _ ->
        error
    end
  end

  defp encode_json(value) do
    case Jason.encode(value) do
      {:ok, _} = result ->
        result

      {:error, error} ->
        {:error, "Could not convert to JSON: #{inspect(error.value)}"}
    end
  end

  defp function_exists?(module, function_name, arity) do
    if function_exported?(module, function_name, arity) do
      :ok
    else
      {:error, "No such function: #{module}.#{function_name}/#{arity}"}
    end
  end

  defp to_module(string) do
    case string do
      ":" <> name ->
        to_atom(name)

      _ ->
        to_atom("Elixir.#{string}")
    end
  end

  defp to_atom(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError ->
      {:error, "No existing atom: #{string}"}
  end
end
