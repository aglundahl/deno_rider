defmodule DenoRiderTerminationTest do
  use ExUnit.Case, async: false

  if :os.type() != {:unix, :linux} do
    @moduletag skip: "counts OS threads through /proc/self/task, which only Linux has"
  end

  test "killing the process stops a runtime that is running JavaScript" do
    {:ok, 1} = DenoRider.eval("1")
    threads_before_start = os_thread_count()
    {:ok, pid} = DenoRider.start()

    catch_exit(DenoRider.eval("while (true) {}", pid: pid, timeout: 100))
    Process.exit(pid, :kill)

    assert wait_for_os_thread_count(threads_before_start) == threads_before_start
  end

  defp wait_for_os_thread_count(expected_count, attempts \\ 20)

  defp wait_for_os_thread_count(_expected_count, 0), do: os_thread_count()

  defp wait_for_os_thread_count(expected_count, attempts) do
    count = os_thread_count()

    if count <= expected_count do
      count
    else
      Process.sleep(100)
      wait_for_os_thread_count(expected_count, attempts - 1)
    end
  end

  defp os_thread_count do
    length(File.ls!("/proc/self/task"))
  end
end
