defmodule PoliteClientTest do
  use ExUnit.Case, async: true
  doctest PoliteClient

  alias PoliteClient.AllocatedRequest

  setup do
    unique_name = make_ref()
    :ok = PoliteClient.start(unique_name, client: fn request -> {:ok, request} end)

    on_exit(fn -> :ok = PoliteClient.stop(unique_name) end)

    %{key: unique_name}
  end

  defp slow_client(sleep \\ 5_000) do
    fn _ ->
      Process.sleep(sleep)
      {:ok, nil}
    end
  end

  test "allocated?/2 and cancel/2" do
    key = make_ref()

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

    test "health checker gets called on each request" do
      key = make_ref()
      me = self()

      {:ok, config} =
        PoliteClient.HealthChecker.config(
          fn _, _ ->
            send(me, :health_checker_called)
            {:ok, nil}
          end,
          nil
        )

      :ok =
        PoliteClient.start(key,
          client: fn request -> {:ok, request} end,
          health_checker: config
        )

      PoliteClient.async_request(key, nil)

      assert_receive :health_checker_called, 500, "Health checker not called on request execution"
    end

    test "rate limiter gets called on each request" do
      key = make_ref()
      me = self()

      {:ok, config} =
        PoliteClient.RateLimiter.config(
          fn _, _ ->
            send(me, :rate_limiter_called)
            {0, nil}
          end,
          nil
        )

      :ok =
        PoliteClient.start(key,
          client: fn request -> {:ok, request} end,
          rate_limiter: config
        )

      PoliteClient.async_request(key, nil)

      assert_receive :rate_limiter_called, 500, "Rate limiter not called on request execution"
    end
  end

  test "start/2", %{key: key} do
    # TODO test for {:error, :max_partitions}
    assert {:error, {:already_started, pid}} =
             PoliteClient.start(key, client: fn _ -> {:ok, :foo} end)

    assert is_pid(pid)
  end

  test "stop/2" do
    start = fn name -> PoliteClient.start(name, client: slow_client()) end

    name = make_ref()

    assert :ok = start.(name)
    assert :ok = PoliteClient.stop(name)

    assert :ok = start.(name)
    %{} = PoliteClient.async_request(name, "foo")

    assert {:error, :busy} = PoliteClient.stop(name)
    assert :ok = PoliteClient.stop(name, force: true)
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

  test "suspend/2 with purging" do
    key = make_ref()
    PoliteClient.start(key, client: slow_client())
    %{ref: ref} = PoliteClient.async_request(key, "some request")
    PoliteClient.suspend(key, purge: true)
    assert_received {^ref, :canceled}, "No cancelation message received"
  end

  test "suspend_all/1", %{key: key} do
    key2 = make_ref()
    PoliteClient.start(key2, client: fn _ -> {:ok, :foo} end)

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
