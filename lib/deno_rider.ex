defmodule DenoRider do
  use GenServer

  alias DenoRider.Error
  alias DenoRider.Native
  alias DenoRider.Runtime

  @doc """
  Start a DenoRider process.

  ## Options

    * `:name` - The name of the process.

  See `start_runtime/1` for more options.

  ## Examples

      iex> DenoRider.start_link(name: MyApp.DenoRider)
      iex> DenoRider.eval("1 + 2", name: MyApp.DenoRider)
      {:ok, 3}
  """
  def start_link(opts) do
    {:ok, runtime} = Keyword.take(opts, [:main_module_path]) |> start_runtime() |> Task.await()

    GenServer.start_link(
      __MODULE__,
      runtime,
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
  Run the given JavaScript code and return the result.

  ## Options

    * `:blocking` - Indicates whether the NIF call should block until the
      JavaScript execution finishes or not. Blocking is more performant, but it
      can also cause problems if the call takes too long. The [NIF
      documentation](https://www.erlang.org/doc/apps/erts/erl_nif.html#lengthy_work)
      suggests that a NIF call shouldn't take more than 1 millisecond. Only set
      this to `true` if you need the performance boost and the execution stays
      below 1 millisecond or so. The default is `false`.
    * `:name` - The name of the DenoRider process. The default is
      `DenoRider`. Can't be provided if `:runtime` is provided.
    * `:runtime` - A runtime from `start_runtime/1`. If `:runtime` is provided,
      `eval/2` will return a `Task` that finishes when the JavaScript exection
      finishes. Can't be provided if `:name` is provided.

  ## Examples

      iex> DenoRider.eval("1 + 2")
      {:ok, 3}

      iex> DenoRider.eval("1 + 2", blocking: true)
      {:ok, 3}

      iex> DenoRider.start_link(name: :foo)
      iex> DenoRider.eval("1 + 2", name: :foo)
      {:ok, 3}

      iex> {:ok, runtime} = DenoRider.start_runtime() |> Task.await()
      iex> DenoRider.eval("1 + 2", runtime: runtime) |> Task.await()
  """
  @spec eval(binary(), Keyword.t()) :: {:ok, term()} | {:error, Error.t()} | Task.t()
  def eval(code, opts) do
    runtime = Keyword.get(opts, :runtime)
    blocking = Keyword.get(opts, :blocking, false)

    case {runtime, blocking} do
      {nil, true} ->
        eval_implicit(code, opts)

      {nil, false} ->
        eval_implicit(code, opts)

      {runtime, true} ->
        eval_runtime_blocking(runtime, code)

      {runtime, false} ->
        eval_runtime_non_blocking(runtime, code)
    end
  end

  defp eval_runtime_blocking(runtime, code) do
    with {:ok, json} <- Native.eval_blocking(runtime.reference, code) do
      Jason.decode(json)
    end
  end

  defp eval_runtime_non_blocking(runtime, code) do
    Task.async(fn ->
      :ok = Native.eval(nil, runtime.reference, code)

      receive do
        {:eval_reply, nil, {:ok, json}} ->
          Jason.decode(json)

        {:eval_reply, nil, error} ->
          error
      end
    end)
  end

  defp eval_implicit(code, opts) do
    Keyword.get(opts, :name, __MODULE__) |> GenServer.call({:eval, code, opts})
  end

  @doc """
  Start a JavaScript runtime and return a `Task` that finishes when runtime has
  started.

  ## Options

    * `:main_module_path` - Path to the main JavaScript module. The default is to start the runtime with an empty main module.

  ## Examples

      iex> DenoRider.start_runtime() |> Task.await()
  """
  @spec start_runtime(Keyword.t()) :: Task.t()
  def start_runtime(opts \\ []) do
    Task.async(fn ->
      :ok =
        Keyword.get(opts, :main_module_path, "#{Application.app_dir(:deno_rider)}/priv/main.js")
        |> Native.start_runtime()

      receive do
        {:ok, reference} ->
          {:ok, %Runtime{reference: reference}}

        error ->
          error
      end
    end)
  end

  @doc """
  Stop a JavaScript runtime and return a `Task` that finishes when runtime has
  stopped.

  ## Examples

      iex> {:ok, runtime} = DenoRider.start_runtime() |> Task.await()
      iex> DenoRider.stop_runtime(runtime) |> Task.await()
  """
  @spec stop_runtime(Runtime.t()) :: Task.t()
  def stop_runtime(runtime) do
    Task.async(fn ->
      :ok = Native.stop_runtime(runtime.reference)

      receive do
        :ok ->
          {:ok, nil}

        error ->
          error
      end
    end)
  end

  @impl GenServer
  def init(initial_arg) do
    {:ok, initial_arg}
  end

  @impl GenServer
  def handle_call({:eval, code, opts}, from, state) do
    if Keyword.get(opts, :blocking, false) do
      {
        :reply,
        with {:ok, json} <- Native.eval_blocking(state.reference, code) do
          Jason.decode(json)
        end,
        state
      }
    else
      Native.eval(from, state.reference, code)
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:eval_reply, from, result}, state) do
    case result do
      {:ok, json} ->
        GenServer.reply(from, Jason.decode(json))
        {:noreply, state}

      {:error, %Error{name: :dead_runtime_error}} ->
        {:stop, {:shutdown, :dead_runtime_error}, state}

      error ->
        GenServer.reply(from, error)
        {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_, state) do
    stop_runtime(state)
  end
end
