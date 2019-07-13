defmodule PoliteClientTest do
  use ExUnit.Case, async: true
  doctest PoliteClient

  alias PoliteClient.AllocatedRequest

  setup do
    client = fn request -> {:ok, request} end

    {:ok, health_checker_config} =
      PoliteClient.HealthChecker.config(fn _, _ -> {:ok, nil} end, nil)

    {:ok, rate_limiter_config} = PoliteClient.RateLimiter.config({:constant, 0})

    partition_opts = [
      client: client,
      health_checker: health_checker_config,
      rate_limiter: rate_limiter_config
    ]

    unique_name = make_ref()
    :ok = PoliteClient.start(unique_name, partition_opts)

    # always terminate all partitions after each test
    on_exit(fn ->
      PoliteClient.PartitionsSupervisor
      |> Supervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(PoliteClient.PartitionsSupervisor, pid)
      end)
    end)

    %{key: unique_name, partition_opts: partition_opts}
  end

  defp slow_client(sleep \\ 5_000) do
    fn _ ->
      Process.sleep(sleep)
      {:ok, nil}
    end
  end

  test "allocated?/2 and cancel/2", %{test: key} do
    PoliteClient.start(key,
      client: fn _ ->
        Process.sleep(10_000)
        {:ok, nil}
      end
    )

    allocated_request = %AllocatedRequest{ref: ref} = PoliteClient.async_request(key, :bar)
    assert PoliteClient.allocated?(allocated_request)

    assert :ok = PoliteClient.cancel(allocated_request)
    assert_received {^ref, :canceled}, "No cancelation message received"
    refute PoliteClient.allocated?(allocated_request)
    assert :ok = PoliteClient.cancel(allocated_request)
    refute_received {^ref, :canceled}, "Duplicate cancelation message received"
  end

  describe "async_request/2" do
    test "sends a message with the result", %{key: key} do
      %{ref: ref} = PoliteClient.async_request(key, "foo")
      assert_receive {^ref, {:ok, "foo"}}, 500, "Request result not received"
    end

    test "can provide client", %{key: key, test: test} do
      %{ref: ref} = PoliteClient.async_request(key, "foo", client: fn _ -> {:ok, test} end)
      assert_receive {^ref, {:ok, ^test}}, 500, "Request result not received"
    end

    test "health checker gets called on each request", %{test: key, partition_opts: opts} do
      pid = self()

      {:ok, config} =
        PoliteClient.HealthChecker.config(
          fn _, _ ->
            send(pid, :health_checker_called)
            {:ok, nil}
          end,
          nil
        )

      :ok = PoliteClient.start(key, Keyword.put(opts, :health_checker, config))

      PoliteClient.async_request(key, nil)

      assert_receive :health_checker_called, 500, "Health checker not called on request execution"
    end

    test "health check can suspend partition", %{test: key, partition_opts: opts} do
      {:ok, config} =
        PoliteClient.HealthChecker.config(
          fn count, _ ->
            status = if count > 0, do: {:suspend, :infinity}, else: :ok
            {status, count + 1}
          end,
          0
        )

      :ok = PoliteClient.start(key, Keyword.put(opts, :health_checker, config))

      %{ref: ref} = PoliteClient.async_request(key, nil)

      receive do
        {^ref, _} -> assert PoliteClient.status(key) == :active
      end

      %{ref: ref} = PoliteClient.async_request(key, nil)

      receive do
        {^ref, _} -> assert PoliteClient.status(key) == :suspended
      end
    end

    test "rate limiter gets called on each request", %{test: key, partition_opts: opts} do
      me = self()

      {:ok, config} =
        PoliteClient.RateLimiter.config(
          fn _, _ ->
            send(me, :rate_limiter_called)
            {0, nil}
          end,
          nil
        )

      :ok = PoliteClient.start(key, Keyword.put(opts, :rate_limiter, config))

      PoliteClient.async_request(key, nil)

      assert_receive :rate_limiter_called, 500, "Rate limiter not called on request execution"
    end

    test "rate limiter can change delay between requests", %{test: key, partition_opts: opts} do
      {:ok, config} =
        PoliteClient.RateLimiter.config(fn count, _ -> {count * 11, count + 1} end, 1,
          min_delay: 0
        )

      :ok = PoliteClient.start(key, Keyword.put(opts, :rate_limiter, config))

      current_delay = fn k ->
        k
        |> PoliteClient.whereis()
        |> :sys.get_state()
        |> PoliteClient.Partition.State.get_current_request_delay()
      end

      %{ref: ref} = PoliteClient.async_request(key, nil)

      receive do
        {^ref, _} -> assert current_delay.(key) == 11
      end

      %{ref: ref} = PoliteClient.async_request(key, nil)

      receive do
        {^ref, _} -> assert current_delay.(key) == 22
      end
    end
  end

  test "start/2", %{key: key, partition_opts: opts} do
    # TODO test for {:error, :max_partitions}
    assert {:error, {:already_started, pid}} = PoliteClient.start(key, opts)

    assert is_pid(pid)
  end

  test "stop/2", %{test: key} do
    start = fn name -> PoliteClient.start(name, client: slow_client()) end

    assert :ok = start.(key)
    assert :ok = PoliteClient.stop(key)

    assert :ok = start.(key)
    %{} = PoliteClient.async_request(key, "foo")

    assert {:error, :busy} = PoliteClient.stop(key)
    assert :ok = PoliteClient.stop(key, force: true)
    assert_received {_ref, :canceled}, "No cancelation message received"

    assert {:error, :no_partition} = PoliteClient.stop(:none)
  end

  test "suspend/2 and resume/2", %{key: key} do
    assert {:error, :no_partition} = PoliteClient.suspend(:none)
    assert {:error, :no_partition} = PoliteClient.resume(:none)

    assert :ok = PoliteClient.suspend(key)
    assert {:error, :suspended} = PoliteClient.suspend(key)

    assert :ok = PoliteClient.resume(key)
    assert %AllocatedRequest{} = PoliteClient.async_request(key, "some request")
    assert :ok = PoliteClient.resume(key)
  end

  test "suspend/2 with purging", %{test: key} do
    PoliteClient.start(key, client: slow_client())
    %{ref: ref} = PoliteClient.async_request(key, "some request")
    PoliteClient.suspend(key, purge: true)
    assert_received {^ref, :canceled}, "No cancelation message received"
  end

  test "suspend_all/1", %{key: key, test: key2, partition_opts: opts} do
    PoliteClient.start(key2, opts)

    PoliteClient.suspend_all()

    assert {:error, :suspended} = PoliteClient.suspend(key)
    assert {:error, :suspended} = PoliteClient.suspend(key2)
  end

  test "whereis/1", %{key: key} do
    pid = PoliteClient.whereis(key)
    assert is_pid(pid)

    assert {:error, :no_partition} = PoliteClient.whereis(:none)
  end
end
