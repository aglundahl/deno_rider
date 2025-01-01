defmodule DenoRiderIsolatesTest do
  use ExUnit.Case, async: true

  import DenoRider

  test "isolate lifecycle" do
    {:ok, runtime} = start_runtime() |> Task.await()

    # Create isolate
    {:ok, isolate_id} = create_isolate(runtime, "test-isolate") |> Task.await()

    # Execute code in isolate
    {:ok, result} = eval_in_isolate(runtime, isolate_id, "1 + 2") |> Task.await()
    assert result == 3

    # Test state persistence in isolate
    {:ok, _} = eval_in_isolate(runtime, isolate_id, "let x = 42") |> Task.await()
    {:ok, value} = eval_in_isolate(runtime, isolate_id, "x") |> Task.await()
    assert value == 42

    # Test isolation between isolates
    {:ok, isolate_id2} = create_isolate(runtime, "test-isolate-2") |> Task.await()

    {:error,
     %{message: "Failed to run script", name: :execution_error, __struct__: DenoRider.Error}} =
      eval_in_isolate(runtime, isolate_id2, "x") |> Task.await()

    # Dispose isolates
    {:ok, nil} = dispose_isolate(runtime, isolate_id2) |> Task.await()
    {:ok, nil} = dispose_isolate(runtime, isolate_id) |> Task.await()
  end

  test "isolate error handling" do
    {:ok, runtime} = start_runtime() |> Task.await()
    {:ok, isolate_id} = create_isolate(runtime, "error-test") |> Task.await()

    # Test syntax error
    {:error, error} = eval_in_isolate(runtime, isolate_id, "invalid js code!!!") |> Task.await()
    assert error.name == :execution_error

    # Test invalid isolate id
    {:error, error} = eval_in_isolate(runtime, "invalid-id", "1 + 1") |> Task.await()
    assert error.name == :execution_error
  end
end
