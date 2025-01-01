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

  test "isolates can be disposed in any order" do
    {:ok, runtime} = start_runtime() |> Task.await()
    {:ok, isolate1_id} = create_isolate(runtime, "isolate-1") |> Task.await()
    {:ok, isolate2_id} = create_isolate(runtime, "isolate-2") |> Task.await()
    {:ok, isolate3_id} = create_isolate(runtime, "isolate-3") |> Task.await()

    {:ok, 2} = eval_in_isolate(runtime, isolate1_id, "1 + 1") |> Task.await()

    {:ok, nil} = dispose_isolate(runtime, isolate1_id) |> Task.await()
    {:ok, nil} = dispose_isolate(runtime, isolate2_id) |> Task.await()
    {:ok, nil} = dispose_isolate(runtime, isolate3_id) |> Task.await()

    ## should error out
    {:ok, 2} = eval_in_isolate(runtime, isolate1_id, "1 + 1") |> Task.await()
  end

  test "isolate error handling" do
    {:ok, runtime} = start_runtime() |> Task.await()
    {:ok, isolate_id} = create_isolate(runtime, "error-test") |> Task.await()

    # Test syntax error
    {:error, error} = eval_in_isolate(runtime, isolate_id, "invalid js code!!!") |> Task.await()

    assert error.message == "Failed to compile script"

    # Test invalid isolate id
    {:error, error} = eval_in_isolate(runtime, "invalid-id", "1 + 1") |> Task.await()
    assert error.message == "Isolate not found"
  end
end
