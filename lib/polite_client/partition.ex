defmodule PoliteClient.Partition do
  @moduledoc false

  # TODO document known limitation: partition doesn't monitor caller, so queued
  # requests will stay in the queue if their caller dies in the meantime. (Caller's
  # liveliness is only checked when spawning the request task.) Therefore, it's
  # possible to refuse new requests due to max queue size, even though some of those
  # requests won't end up being made.

  use GenServer

  require Logger

  alias PoliteClient.{AllocatedRequest, Client, ResponseMeta}
  alias PoliteClient.Partition.{PendingRequest, State}

  def start_link(args) do
    # TODO verify args contains :client
    GenServer.start_link(__MODULE__, args, args)
  end

  @spec async_request(GenServer.name(), Client.request()) ::
          AllocatedRequest.t()
          | {:error, :max_queued | :suspended | {:retries_exhausted, last_error :: term()}}
  def async_request(name, request) do
    GenServer.call(name, {:request, request})
  end

  @spec allocated?(GenServer.name(), reference()) :: boolean()
  def allocated?(name, ref) do
    GenServer.call(name, {:allocated?, ref})
  end

  @spec cancel(GenServer.name(), AllocatedRequest.t()) :: boolean()
  def cancel(name, %AllocatedRequest{} = allocation) do
    GenServer.call(name, {:cancel, allocation})
  end

  @spec suspend(GenServer.name(), Keyword.t()) :: :ok
  def suspend(name, opts \\ []) do
    GenServer.call(name, {:suspend, opts})
  end

  @spec resume(GenServer.name()) :: :ok
  def resume(name) do
    GenServer.call(name, :resume)
  end

  @impl GenServer
  def init(args) do
    case State.from_keywords(args) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:resume, _from, state) do
    {:reply, :ok, do_resume(state)}
  end

  @impl GenServer
  def handle_call({:allocated?, ref}, _from, state) do
    {:reply, State.queued?(state, ref) || State.in_flight?(state, ref), state}
  end

  @impl GenServer
  def handle_call({:cancel, %AllocatedRequest{} = allocation}, _from, state) do
    {to_cancel, remaining} =
      Enum.split_with(state.in_flight_requests, fn
        {_task_ref, pending_request} ->
          PendingRequest.for_allocation?(pending_request, allocation)
      end)

    Enum.each(to_cancel, fn {_, %PendingRequest{task: %Task{ref: ref, pid: pid}}} ->
      Process.demonitor(ref, [:flush])
      :ok = Task.Supervisor.terminate_child(state.task_supervisor, pid)
    end)

    state =
      state
      |> State.delete_queued_requests_by_allocation(allocation)
      |> schedule_next_request()
      |> State.set_in_flight_requests(Enum.into(remaining, %{}))

    {:reply, :canceled, state}
  end

  @impl GenServer
  def handle_call(_, _from, %{status: {:suspended, _}} = state) do
    {:reply, {:error, :suspended}, state}
  end

  @impl GenServer
  def handle_call({:suspend, opts}, _from, state) do
    state =
      case Keyword.get(opts, :purge) do
        true -> purge_all_requests(state)
        _ -> state
      end

    {:reply, :ok, State.suspend(state)}
  end

  @impl GenServer
  def handle_call(
        {:request, _request},
        _from,
        %{queued_requests: queued, max_queued: max} = state
      )
      when length(queued) >= max do
    {:reply, {:error, :max_queued}, state}
  end

  @impl GenServer
  def handle_call({:request, request}, {pid, _}, state) do
    pending_request = %PendingRequest{
      request: request,
      allocation: %AllocatedRequest{
        ref: make_ref(),
        owner: pid,
        partition: state.key
      }
    }

    state =
      state
      |> State.enqueue(pending_request)
      |> maybe_process_next_request()

    {:reply, PendingRequest.get_allocation(pending_request), state}
  end

  @impl GenServer
  def handle_info(:auto_resume, %{status: {:suspended, :infinity}} = state), do: {:noreply, state}

  @impl GenServer
  def handle_info(:auto_resume, state), do: {:noreply, do_resume(state)}

  @impl GenServer
  def handle_info({task_ref, %ResponseMeta{} = response_meta}, state)
      when is_reference(task_ref) do
    Process.demonitor(task_ref, [:flush])

    state =
      state
      |> State.set_unavailable()
      |> suspend_if_not_healthy(response_meta)
      |> handle_request_result(response_meta, task_ref)
      |> State.delete_in_flight_request(task_ref)
      |> State.update_rate_limiter_state(response_meta)
      |> schedule_next_request()

    {:noreply, state}
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
    state
    |> State.update_health_checker_state(response_meta)
    |> State.check_health()
    |> case do
      {:suspend, :infinity} ->
        State.suspend(state, :infinity)

      {:suspend, duration} ->
        # TODO document: suspend at least as long as delay before next request
        duration = max(duration, State.get_current_request_delay(state))
        State.suspend(state, Process.send_after(self(), :auto_resume, duration))

      :ok ->
        state
    end
  end

  defp do_resume(%{status: :active} = state), do: state

  # TODO document that on resume, next request is sent immediately
  defp do_resume(%{status: {:suspended, maybe_ref}} = state) do
    if is_reference(maybe_ref) do
      Process.cancel_timer(maybe_ref)
    end

    # TODO NOW clear rate_limiter and health states => store initial states in state

    process_next_request(%{state | status: :active})
  end

  @spec handle_request_result(
          state :: State.t(),
          response_meta :: ResponseMeta.t(),
          task_ref :: reference()
        ) :: State.t()
  defp handle_request_result(state, %ResponseMeta{result: result}, task_ref) do
    pending_request = State.get_in_flight_request(state, task_ref)
    %AllocatedRequest{ref: ref, owner: pid} = PendingRequest.get_allocation(pending_request)

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

  defp process_next_request(%{queued_requests: []} = state) do
    %{state | available: true}
  end

  defp process_next_request(%{queued_requests: q} = state) do
    [%PendingRequest{allocation: allocation} = next | t] = q
    %AllocatedRequest{owner: pid} = allocation

    state =
      if Process.alive?(pid) do
        %Task{ref: task_ref} =
          task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            {duration, result} = :timer.tc(fn -> state.client.(next.request) end)

            %ResponseMeta{
              result: result,
              duration: duration
            }
          end)

        State.add_in_flight_request(state, task_ref, %{next | task: task})
      else
        process_next_request(%{state | queued_requests: t})
      end

    State.set_queued_requests(state, t)
  end

  defp purge_all_requests(%{in_flight_requests: in_flight, queued_requests: queued} = state) do
    in_flight
    |> Map.values()
    |> Enum.each(&cancel_in_flight_request/1)

    Enum.each(queued, fn %PendingRequest{allocation: %AllocatedRequest{ref: ref, owner: pid}} ->
      send_cancelation(ref, pid)
    end)

    %{state | in_flight_requests: %{}, queued_requests: []}
  end

  defp cancel_in_flight_request(%PendingRequest{task: task} = pending_req) do
    %AllocatedRequest{ref: ref, owner: pid} = pending_req.allocation

    case Task.shutdown(task) do
      {:ok, {_duration, result}} -> send(pid, {ref, result})
      _res -> send(pid, {ref, :canceled})
    end
  end

  defp send_cancelation(ref, pid), do: send(pid, {ref, :canceled})
end
