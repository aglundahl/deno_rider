defmodule DenoRiderTest do
  use ExUnit.Case, async: true

  import DenoRider

  alias DenoRider.Error

  test "async mode" do
    assert {:ok, 3} = eval("1 + 2")
  end

  test "blocking mode" do
    assert {:ok, 3} = eval("1 + 2", blocking: true)
  end

  describe "return values" do
    test "null" do
      assert {:ok, nil} = eval("null")
    end

    test "undefined" do
      assert {:ok, nil} = eval("undefined")
    end

    test "boolean" do
      assert {:ok, true} = eval("true")
      assert {:ok, false} = eval("false")
    end

    test "string" do
      assert {:ok, "bar"} = eval("'bar'")
    end

    test "number" do
      assert {:ok, 2} = eval("2")
    end

    test "array" do
      assert {:ok, ["bar"]} = eval("['bar']")
    end

    test "object" do
      assert {:ok, %{"bar" => "baz"}} = eval("({bar: 'baz'})")
    end
  end

  test "state persistence" do
    {:ok, runtime_1} = start_runtime() |> Task.await()
    {:ok, runtime_2} = start_runtime() |> Task.await()

    eval("globalThis.foo = 1", blocking: true, runtime: runtime_1)
    eval("globalThis.foo = 2", blocking: true, runtime: runtime_2)

    assert {:ok, 1} = eval("globalThis.foo", runtime: runtime_1) |> Task.await()
    assert {:ok, 1} = eval("globalThis.foo", blocking: true, runtime: runtime_1)
    assert {:ok, 2} = eval("globalThis.foo", runtime: runtime_2) |> Task.await()
    assert {:ok, 2} = eval("globalThis.foo", blocking: true, runtime: runtime_2)
  end

  test "event loop" do
    eval("""
    globalThis.foo = 1;
    setTimeout(() => globalThis.foo = 2, 100);
    setTimeout(() => globalThis.foo = 3, 200);
    """)

    assert {:ok, 1} = eval("globalThis.foo")
    Process.sleep(150)
    assert {:ok, 2} = eval("globalThis.foo")
    Process.sleep(100)
    assert {:ok, 3} = eval("globalThis.foo")
  end

  test "main module" do
    {:ok, runtime} =
      start_runtime(main_module_path: "test/support/main_module.js") |> Task.await()

    assert {:ok, "this is a main module"} =
             eval("globalThis.foo", blocking: true, runtime: runtime)

    assert {:ok, "this is from another tick"} =
             eval("globalThis.bar", blocking: true, runtime: runtime)
  end

  test "import files" do
    {:ok, runtime} =
      start_runtime(main_module_path: "test/support/import_files_a.js") |> Task.await()

    assert {:ok, "this is a file to import"} =
             eval("globalThis.foo", blocking: true, runtime: runtime)
  end

  test "read file" do
    assert(
      {:ok, "this is a file to read\n"} =
        eval("new TextDecoder('utf-8').decode(Deno.readFileSync('test/support/read_file.txt'))")
    )
  end

  test "Node APIs" do
    {:ok, runtime} = start_runtime(main_module_path: "test/support/node_apis.js") |> Task.await()

    assert {:ok, "this%20is%20converted%20using%20Node%20APIs"} =
             eval("globalThis.foo", blocking: true, runtime: runtime)
  end

  test "eval with syntax error" do
    assert(
      {
        :error,
        %Error{
          message: "Uncaught SyntaxError: Unexpected token ')'\n    at <anon>:1:1",
          name: :execution_error
        }
      } = eval(")", blocking: true)
    )

    assert {:ok, 3} = eval("1 + 2", blocking: true)
  end

  test "main module with syntax error" do
    assert(
      {
        :error,
        %Error{
          message: "Uncaught SyntaxError: Unexpected token ')'\n    at file://" <> _,
          name: :execution_error
        }
      } = start_runtime(main_module_path: "test/support/syntax_error.js") |> Task.await()
    )
  end

  test "non-existent main module" do
    assert(
      {
        :error,
        %Error{
          message: "Failed to load file:///foo",
          name: :execution_error
        }
      } = start_runtime(main_module_path: "/foo") |> Task.await()
    )
  end

  test "stop runtime" do
    {:ok, runtime} = start_runtime() |> Task.await()

    assert {:ok, nil} = stop_runtime(runtime) |> Task.await()

    assert {:error, %Error{name: :dead_runtime_error}} =
             eval("1 + 2", blocking: true, runtime: runtime)

    assert {:error, %Error{name: :dead_runtime_error}} = stop_runtime(runtime) |> Task.await()
  end

  @tag :panic
  test "kill runtime" do
    {:ok, runtime} = start_runtime() |> Task.await()

    # We currently don't support returning symbols, so we use that to make the
    # worker thread panic.
    assert {:error, %Error{name: :execution_error}} =
             eval("Symbol('foo')", blocking: true, runtime: runtime)

    assert {:error, %Error{name: :dead_runtime_error}} =
             eval("1 + 2", blocking: true, runtime: runtime)
  end

  @tag :benchmark
  test "benchmark" do
    Benchee.run(%{
      "eval" => fn ->
        {:ok, 1} = eval("1")
      end,
      "eval with blocking" => fn ->
        {:ok, 1} = eval("1", blocking: true)
      end
    })
  end
end
