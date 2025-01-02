defmodule DenoRiderIsolatesTest do
  use ExUnit.Case, async: true

  test "isolate lifecycle" do
    {:ok, runtime} = DenoRider.start_runtime() |> Task.await()

    # Create isolate
    {:ok, isolate_id} = DenoRider.create_isolate(runtime, "test-isolate") |> Task.await()

    # Execute code in isolate
    {:ok, result} = DenoRider.eval_in_isolate(runtime, isolate_id, "1 + 2") |> Task.await()
    assert result == 3

    # Test state persistence in isolate
    {:ok, _} = DenoRider.eval_in_isolate(runtime, isolate_id, "let x = 42") |> Task.await()
    {:ok, value} = DenoRider.eval_in_isolate(runtime, isolate_id, "x") |> Task.await()
    assert value == 42

    # Test isolation between isolates
    {:ok, isolate_id2} = DenoRider.create_isolate(runtime, "test-isolate-2") |> Task.await()

    {:error,
     %{message: "Failed to run script", name: :execution_error, __struct__: DenoRider.Error}} =
      DenoRider.eval_in_isolate(runtime, isolate_id2, "x") |> Task.await()

    # Dispose isolates
    {:ok, {}} = DenoRider.dispose_isolate(runtime, isolate_id2) |> Task.await()
    {:ok, {}} = DenoRider.dispose_isolate(runtime, isolate_id) |> Task.await()

    assert {:ok, nil} = DenoRider.stop_runtime(runtime) |> Task.await()
  end

  test "isolates out of order disposal doesn't cause panic" do
    {:ok, runtime} = DenoRider.start_runtime() |> Task.await()
    {:ok, isolate1_id} = DenoRider.create_isolate(runtime, "isolate-1") |> Task.await()
    {:ok, isolate2_id} = DenoRider.create_isolate(runtime, "isolate-2") |> Task.await()
    {:ok, isolate3_id} = DenoRider.create_isolate(runtime, "isolate-3") |> Task.await()

    ## isolate1 allows execution
    {:ok, 2} = DenoRider.eval_in_isolate(runtime, isolate1_id, "1 + 1") |> Task.await()

    ## isolates disposal MUST happen in reverse order! (enforced by Deno Runtime)
    {:error,
     %{
       name: :execution_error,
       __struct__: DenoRider.Error
     } = error} = DenoRider.dispose_isolate(runtime, isolate1_id) |> Task.await()

    assert isolate3_id == "isolate-3"
    assert error.message == "Isolate #{isolate3_id} must be disposed first"

    ## we dispose isolates correctly
    assert {:ok, {}} = DenoRider.dispose_isolate(runtime, isolate3_id) |> Task.await()
    assert {:ok, {}} = DenoRider.dispose_isolate(runtime, isolate2_id) |> Task.await()
    assert {:ok, {}} = DenoRider.dispose_isolate(runtime, isolate1_id) |> Task.await()

    ## how the isolate1 must be disposed
    {:error, %{message: "Isolate not found", name: :execution_error, __struct__: DenoRider.Error}} =
      DenoRider.eval_in_isolate(runtime, isolate1_id, "1 + 1") |> Task.await()
  end

  test "isolate error handling" do
    {:ok, runtime} = DenoRider.start_runtime() |> Task.await()
    {:ok, isolate_id} = DenoRider.create_isolate(runtime, "error-test") |> Task.await()

    # Test syntax error
    {:error, error} =
      DenoRider.eval_in_isolate(runtime, isolate_id, "invalid js code!!!") |> Task.await()

    assert error.message == "Failed to compile script"

    # Test invalid isolate id
    {:error, error} = DenoRider.eval_in_isolate(runtime, "invalid-id", "1 + 1") |> Task.await()
    assert error.message == "Isolate not found"
    assert {:ok, nil} = DenoRider.stop_runtime(runtime) |> Task.await()
  end

  test "no sharing of state with the runtime" do
    {:ok, runtime} = DenoRider.start_runtime() |> Task.await()
    ## set some global state in runtime
    DenoRider.eval("globalThis.foo = 999", runtime: runtime) |> Task.await()
    {:ok, 999} = DenoRider.eval("globalThis.foo", runtime: runtime) |> Task.await()

    {:ok, isolate1_id} = DenoRider.create_isolate(runtime, "isolate-1") |> Task.await()
    ## this state is not shared with isolate-1
    {:ok, nil} = DenoRider.eval_in_isolate(runtime, isolate1_id, "globalThis.foo") |> Task.await()

    {:ok, isolate2_id} = DenoRider.create_isolate(runtime, "isolate-2") |> Task.await()
    {:ok, _isolate3_id} = DenoRider.create_isolate(runtime, "isolate-3") |> Task.await()

    DenoRider.dispose_isolate(runtime, isolate2_id) |> Task.await()
  end

  test "automatic runtime disposal" do
    {:ok, runtime} = DenoRider.start_runtime() |> Task.await()
    {:ok, isolate_id} = DenoRider.create_isolate(runtime, "isolate-1") |> Task.await()
    {:ok, nil} = DenoRider.eval_in_isolate(runtime, isolate_id, "globalThis.foo") |> Task.await()
  end
end
