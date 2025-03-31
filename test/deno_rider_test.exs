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
    {:ok, pid_1} = start()
    {:ok, pid_2} = start()

    eval("globalThis.foo = 1", blocking: true, pid: pid_1)
    eval("globalThis.foo = 2", blocking: true, pid: pid_2)

    assert {:ok, 1} = eval("globalThis.foo", pid: pid_1)
    assert {:ok, 1} = eval("globalThis.foo", blocking: true, pid: pid_1)
    assert {:ok, 2} = eval("globalThis.foo", pid: pid_2)
    assert {:ok, 2} = eval("globalThis.foo", blocking: true, pid: pid_2)
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
    {:ok, pid} = start(main_module_path: "test/support/main_module.js")

    assert {:ok, "this is a main module"} = eval("globalThis.foo", blocking: true, pid: pid)
    assert {:ok, "this is from another tick"} = eval("globalThis.bar", blocking: true, pid: pid)
  end

  test "import files" do
    {:ok, pid} = start(main_module_path: "test/support/import_files_a.js")

    assert {:ok, "this is a file to import"} = eval("globalThis.foo", blocking: true, pid: pid)
  end

  test "read file" do
    assert(
      {:ok, "this is a file to read\n"} =
        eval("new TextDecoder('utf-8').decode(Deno.readFileSync('test/support/read_file.txt'))")
    )
  end

  test "Node APIs" do
    {:ok, pid} = start(main_module_path: "test/support/node_apis.js")

    assert {:ok, "this%20is%20converted%20using%20Node%20APIs"} =
             eval("globalThis.foo", blocking: true, pid: pid)
  end

  test "eval with syntax error" do
    assert {:error, %Error{name: :execution_error} = error} = eval(")", blocking: true)

    assert Exception.message(error) ==
             "execution_error: Uncaught SyntaxError: Unexpected token ')'\n    at <anon>:1:1"

    assert {:ok, 3} = eval("1 + 2", blocking: true)
  end

  test "main module with syntax error" do
    assert {:error, %Error{name: :execution_error} = error} =
             start(main_module_path: "test/support/syntax_error.js")

    assert Exception.message(error) =~
             "execution_error: Uncaught SyntaxError: Unexpected token ')'\n    at file:///"
  end

  test "non-existent main module" do
    assert {:error, %Error{name: :execution_error} = error} = start(main_module_path: "/foo")
    assert Exception.message(error) == "execution_error: Failed to load file:///foo"
  end

  test "stop runtime" do
    {:ok, pid} = start()

    assert :ok = stop(pid: pid)
    assert Process.alive?(pid) == false
  end

  describe "promises" do
    test "resolve" do
      assert {:ok, 3} = eval("new Promise((resolve) => { setTimeout(() => resolve(3), 100) })")
    end

    test "reject" do
      assert {:error, %Error{name: :promise_rejection, value: 3} = error} =
               eval("new Promise((_, reject) => { setTimeout(() => reject(3), 100) })")

      assert Exception.message(error) == "promise_rejection"
    end

    test "already resolved" do
      assert {:ok, 3} = eval("Promise.resolve(3)")
    end

    test "already rejected" do
      assert {:error, %Error{name: :promise_rejection, value: 3} = error} =
               eval("Promise.reject(3)")

      assert Exception.message(error) == "promise_rejection"
    end
  end

  describe "JavaScript API: apply" do
    test "Elixir module" do
      assert {:ok, 3} = eval("DenoRider.apply('Kernel', '+', [1, 2])")
    end

    test "Erlang module" do
      assert {:ok, 3} = eval("DenoRider.apply(':math', 'floor', [3.14])")
    end

    test "round trip" do
      {:ok, pid} = start()

      assert {:ok, 3} = eval("DenoRider.apply('DenoRider', 'eval!', ['1 + 2'])", pid: pid)
    end

    test "HTTP server" do
      {:ok, _} = start(main_module_path: "test/support/server.js")

      assert {:ok, {_, _, ~c"Result: 3"}} = :httpc.request("http://localhost:3000")
    end

    test "without JSON encodable return value" do
      assert {:error,
              %Error{name: :promise_rejection, value: "Could not convert to JSON: {1, 2, 3}"} =
                error} = eval("DenoRider.apply('List', 'to_tuple', [[1, 2, 3]])")

      assert Exception.message(error) == "promise_rejection"
    end

    test "invalid module" do
      assert {:error, %Error{name: :execution_error} = error} =
               eval("DenoRider.apply(1, '+', [1, 2])")

      assert Exception.message(error) ==
               "execution_error: Error: Not a string: 1\n    at Object.apply (ext:extension/main.js:14:13)\n    at <anon>:1:11"

      assert {:error,
              %Error{name: :promise_rejection, value: "No existing atom: Elixir.Foo"} = error} =
               eval("DenoRider.apply('Foo', '+', [1, 2])")

      assert Exception.message(error) == "promise_rejection"
    end

    test "invalid function" do
      assert {:error, %Error{name: :execution_error} = error} =
               eval("DenoRider.apply('Kernel', 1, [1, 2])")

      assert Exception.message(error) ==
               "execution_error: Error: Not a string: 1\n    at Object.apply (ext:extension/main.js:17:13)\n    at <anon>:1:11"

      assert {:error,
              %Error{name: :promise_rejection, value: "No such function: Elixir.Kernel.foo/2"} =
                error} = eval("DenoRider.apply('Kernel', 'foo', [1, 2])")

      assert Exception.message(error) == "promise_rejection"
    end

    test "invalid args" do
      assert {:error, %Error{name: :execution_error} = error} =
               eval("DenoRider.apply('Kernel', '+', 1)")

      assert Exception.message(error) ==
               "execution_error: Error: Not an array: 1\n    at Object.apply (ext:extension/main.js:20:13)\n    at <anon>:1:11"

      assert {:error,
              %Error{name: :promise_rejection, value: "No such function: Elixir.Kernel.+/3"} =
                error} = eval("DenoRider.apply('Kernel', '+', [1, 2, 3])")

      assert Exception.message(error) == "promise_rejection"
    end
  end

  @tag :panic
  test "kill runtime" do
    {:ok, pid} = start()

    # We currently don't support returning symbols, so we use that to make the
    # worker thread panic.
    assert {:error, %Error{name: :execution_error} = error} =
             eval("Symbol('foo')", blocking: true, pid: pid)

    assert Exception.message(error) == "execution_error"

    assert {{:shutdown, :dead_runtime_error}, _} =
             catch_exit(eval("1 + 2", blocking: true, pid: pid))

    assert Process.alive?(pid) == false
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
