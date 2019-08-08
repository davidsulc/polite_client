defmodule PoliteClient.Partition do
  @moduledoc false

  use GenServer

  require Logger

  alias PoliteClient.{AllocatedRequest, Client, ResponseMeta}
  alias PoliteClient.Partition.{PendingRequest, State}

  @spec start_link(Keyword.t()) :: GenServer.on_start() | {:error, {:client, :not_provided}}
  def start_link(args) do
    args
    |> Keyword.get(:client)
    |> case do
      {:error, reason} -> {:error, {:client, reason}}
      _ -> GenServer.start_link(__MODULE__, args, args)
    end
  end

  @doc "Executes a request asynchronously."
  @spec async_request(GenServer.name(), Client.request(), Keyword.t()) ::
          AllocatedRequest.t() | {:error, :max_queued | :suspended}
  def async_request(name, request, opts \\ []) do
    GenServer.call(name, {:request, request, opts})
  end

  @doc "Returns true if the request is still allocated."
  @spec allocated?(GenServer.name(), reference()) :: boolean()
  def allocated?(name, ref) do
    GenServer.call(name, {:allocated?, ref})
  end

  @doc "Returns true if the partition has no pending requests."
  @spec idle?(GenServer.name()) :: boolean()
  def idle?(name) do
    GenServer.call(name, :idle?)
  end

  @doc "Cancel the request."
  @spec cancel(GenServer.name(), AllocatedRequest.t()) :: :ok
  def cancel(name, %AllocatedRequest{} = allocation) do
    GenServer.call(name, {:cancel, allocation})
  end

  @doc "Suspend the partition."
  @spec suspend(GenServer.name(), Keyword.t()) :: :ok
  def suspend(name, opts \\ []) do
    GenServer.call(name, {:suspend, opts})
  end

  @doc "Unsuspend partition."
  @spec resume(GenServer.name()) :: :ok
  def resume(name) do
    GenServer.call(name, :resume)
  end

  @doc "Returns the status"
  @spec status(GenServer.name()) :: State.status()
  def status(name) do
    GenServer.call(name, :status)
  end

  @impl GenServer
  def init(args) do
    # Trap exits so the terminate/2 callback will be called if this partition is terminated,
    # which will allow cleanup and canceling the remaining pending requests.
    Process.flag(:trap_exit, true)

    case State.from_keywords(args) do
      {:ok, state} ->
        Logger.metadata(partition: state.key)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, State.get_status(state), state}
  end

  @impl GenServer
  # on resume, next request is sent immediately (b/c the rate limiter and health checker
  # states are reinitialized (which isn't true in the auto-resume case)
  def handle_call(:resume, _from, state) do
    state =
      state
      |> State.reset_rate_limiter_internal_state()
      |> State.reset_health_checker_internal_state()
      |> do_resume()

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:allocated?, ref}, _from, state) do
    {:reply, State.queued?(state, ref) || State.in_flight?(state, ref), state}
  end

  @impl GenServer
  def handle_call(:idle?, _from, state) do
    %{queued_requests: queued, in_flight_requests: in_flight} = state
    {:reply, queued == [] && Map.size(in_flight) == 0, state}
  end

  @impl GenServer
  def handle_call({:cancel, %AllocatedRequest{ref: ref} = allocation}, _from, state) do
    Logger.info("Canceling request #{inspect(ref)}")

    {in_flight_to_cancel, in_flight_remaining} =
      state.in_flight_requests
      |> Map.values()
      |> Enum.split_with(&PendingRequest.for_allocation?(&1, allocation))

    {queued_to_cancel, queued_remaining} =
      Enum.split_with(state.queued_requests, &PendingRequest.for_allocation?(&1, allocation))

    Enum.each(in_flight_to_cancel ++ queued_to_cancel, &PendingRequest.cancel/1)

    state =
      state
      |> State.set_queued_requests(queued_remaining)
      |> State.set_in_flight_requests(Enum.into(in_flight_remaining, %{}))
      |> schedule_next_request()

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(_, _from, %{status: {:suspended, _}} = state) do
    {:reply, {:error, :suspended}, state}
  end

  @impl GenServer
  def handle_call({:suspend, opts}, _from, state) do
    Logger.info("Suspending")

    state =
      case Keyword.get(opts, :purge) do
        true -> purge_all_requests(state)
        _ -> state
      end

    {:reply, :ok, State.suspend(state)}
  end

  @impl GenServer
  def handle_call(
        {:request, _request, _opts},
        _from,
        %{queued_requests: queued, max_queued: max} = state
      )
      when length(queued) >= max do
    Logger.warn("Received request: over capacity (max_queued: #{max})")
    {:reply, {:error, :max_queued}, state}
  end

  @impl GenServer
  def handle_call({:request, request, opts}, {pid, _}, state) do
    pending_request = %PendingRequest{
      request: request,
      client: Keyword.get(opts, :client, state.client),
      allocation: %AllocatedRequest{
        ref: ref = make_ref(),
        owner: pid,
        partition: state.key
      }
    }

    Logger.debug("Received request: allocated with ref #{inspect(ref)}")

    state =
      state
      |> State.enqueue(pending_request)
      |> maybe_process_next_request()

    {:reply, PendingRequest.get_allocation(pending_request), state}
  end

  @impl GenServer
  def handle_info(:auto_resume, %{status: {:suspended, :infinity}} = state) do
    Logger.info("Auto-resume attempt ignored: in suspended state with :infinity")
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:auto_resume, state) do
    Logger.info("Auto-resuming")
    {:noreply, do_resume(state)}
  end

  @impl GenServer
  def handle_info({task_ref, %ResponseMeta{result: result} = response_meta}, state)
      when is_reference(task_ref) do
    Process.demonitor(task_ref, [:flush])

    Client.validate_result(result)

    state =
      state
      |> suspend_if_not_healthy(response_meta)
      |> handle_request_result(response_meta, task_ref)
      |> State.delete_in_flight_request(task_ref)
      |> State.update_rate_limiter_state(response_meta)

    {:noreply, schedule_next_request(state)}
  end

  @impl GenServer
  # The task merely wraps the client call to time it, and is therefore not expected to fail (assuming
  # the client isn't faulty). Consequently, we just log the failure and don't attempt to restart the task.
  def handle_info({:DOWN, task_ref, :process, _task_pid, {reason, _}}, state)
      when is_reference(task_ref) do
    pending_request = %PendingRequest{request: req} = State.get_in_flight_request(state, task_ref)
    %AllocatedRequest{ref: ref, owner: pid} = PendingRequest.get_allocation(pending_request)

    Logger.error("Task failed", request_ref: ref, request: req)
    send(pid, {ref, {:error, {:task_failed, Map.get(reason, :message, "unknown")}}})

    state =
      state
      |> State.delete_in_flight_request(task_ref)
      |> process_next_request()

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:process_next_request, state) do
    {:noreply, process_next_request(state)}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.error("Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state), do: purge_all_requests(state)

  defp suspend_if_not_healthy(%State{} = state, %ResponseMeta{} = response_meta) do
    state = State.update_health_checker_state(state, response_meta)

    case State.check_health(state) do
      {:suspend, :infinity} ->
        Logger.warn("Health check failed, suspending for :infinity")
        State.suspend(state, :infinity)

      {:suspend, duration} ->
        Logger.warn("Health check failed, suspending for #{duration} milliseconds")
        State.suspend(state, Process.send_after(self(), :auto_resume, duration))

      :ok ->
        state

      bad_result ->
        raise "expected health status to conform to `PoliteClient.HealthChecker.status()`, but got #{
                inspect(bad_result)
              }. " <>
                "Make sure the `checker/2` function provided within the `health_checker` configuration conforms to the " <>
                "t:PoliteClient.HealthChecker.checker/0` spec."
    end
  end

  defp do_resume(%{status: :active} = state), do: state

  defp do_resume(%{status: {:suspended, maybe_ref}} = state) do
    if is_reference(maybe_ref) do
      Process.cancel_timer(maybe_ref)
    end

    state
    |> State.set_status(:active)
    |> process_next_request()
  end

  @spec handle_request_result(
          state :: State.t(),
          response_meta :: ResponseMeta.t(),
          task_ref :: reference()
        ) :: State.t()
  defp handle_request_result(state, %ResponseMeta{result: result}, task_ref) do
    pending_request = State.get_in_flight_request(state, task_ref)
    %AllocatedRequest{ref: ref, owner: pid} = PendingRequest.get_allocation(pending_request)

    Logger.debug("Forwarding request result #{inspect(ref)} to owner #{inspect(pid)}")

    case result do
      {:ok, _} ->
        send(pid, {ref, result})
        state

      {:error, _} = error ->
        if pending_request.retries > state.max_retries do
          send(pid, {ref, {:error, {:retries_exhausted, error}}})
          state
        else
          pending_request = %{pending_request | retries: pending_request.retries + 1}
          %{state | queued_requests: [pending_request | state.queued_requests]}
        end
    end
  end

  defp schedule_next_request(%{status: {:suspended, _}} = state), do: state

  defp schedule_next_request(state) do
    Process.send_after(self(), :process_next_request, State.get_current_request_delay(state))
    state
  end

  defp maybe_process_next_request(%State{available: false} = state), do: state

  defp maybe_process_next_request(%State{available: true} = state) do
    state
    |> State.set_unavailable()
    |> process_next_request()
  end

  defp process_next_request(%{queued_requests: []} = state), do: State.set_available(state)

  defp process_next_request(%{status: {:suspended, _}} = state), do: state

  defp process_next_request(%{queued_requests: q} = state) do
    [%PendingRequest{client: client, allocation: allocation} = next | t] = q
    %AllocatedRequest{owner: pid, ref: ref} = allocation

    state =
      if Process.alive?(pid) do
        %Task{ref: task_ref} =
          task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            {duration, result} = :timer.tc(fn -> client.(next.request) end)

            %ResponseMeta{
              result: result,
              duration: duration
            }
          end)

        Logger.debug("Processing request #{inspect(ref)} -> task ref #{inspect(task_ref)}")

        State.add_in_flight_request(state, task_ref, %{next | task: task})
      else
        Logger.debug("Discarding request #{inspect(ref)}: owner dead")
        process_next_request(%{state | queued_requests: t})
      end

    state
    |> State.set_unavailable()
    |> State.set_queued_requests(t)
  end

  defp purge_all_requests(%{in_flight_requests: in_flight, queued_requests: queued} = state) do
    Logger.info("Purging all requests")

    in_flight
    |> Map.values()
    |> Enum.each(&PendingRequest.cancel/1)

    Enum.each(queued, &PendingRequest.cancel/1)

    %{state | in_flight_requests: %{}, queued_requests: []}
  end
end
