defmodule PoliteClient.Partition do
  @moduledoc false

  # TODO document known limitation: partition doesn't monitor caller, so queued
  # requests will stay in the queue if their caller dies in the meantime. (Caller's
  # liveliness is only checked when spawning the request task.) Therefore, it's
  # possible to refuse new requests due to max queue size, even though some of those
  # requests won't end up being made.

  use GenServer

  require Logger

  alias PoliteClient.{AllocatedRequest, RateLimiter, Request}

  defmodule PendingRequest do
    @type t :: %__MODULE__{
            allocation: AllocatedRequest.t(),
            request: Request.t(),
            task: nil | Task.t(),
            retries: non_neg_integer()
          }

    @enforce_keys [:allocation, :request]
    defstruct allocation: nil, request: nil, task: nil, retries: 0
  end

  @max_queued 50
  @max_retries 3

  @type http_client() ::
          (Request.t() -> {:ok, request_result :: term()} | {:error, request_result :: term()})

  def start_link(args) do
    # TODO verify args contains :http_client
    GenServer.start_link(__MODULE__, args, args)
  end

  @spec async_request(GenServer.name(), Request.t()) ::
          AllocatedRequest.t()
          | {:error, :max_queued | :suspended | {:retries_exhausted, last_error :: term()}}
  def async_request(name, %Request{} = request) do
    GenServer.call(name, {:request, request})
  end

  @spec allocated?(GenServe.name(), reference()) :: boolean()
  def allocated?(name, ref) do
    GenServer.call(name, {:allocated?, ref})
  end

  @spec cancel(GenServe.name(), reference()) :: boolean()
  def cancel(name, ref) do
    GenServer.call(name, {:cancel, ref})
  end

  @spec suspend(GenServer.name(), Keyword.t()) :: :ok
  def suspend(name, opts \\ []) do
    GenServer.call(name, {:suspend, :manual, opts})
  end

  @spec resume(GenServer.name()) :: :ok
  def resume(name) do
    GenServer.call(name, :resume)
  end

  @impl GenServer
  def init(args) do
    with {:ok, http_client} <- http_client(args),
         {:ok, rate_limiter_config} <- rate_limiter_config(args) do
      state = %{
        key: Keyword.fetch!(args, :key),
        status: :active,
        # indicates whether a request can be made (given rate limiting): it's not enough
        # for the queue to be empty (b/c the last request may have been made too recently)
        available: true,
        http_client: http_client,
        rate_limiter: rate_limiter_config,
        # TODO NOW
        health_checker: %{
          checker: fn nil, _ref -> {{:suspend, 3_000}, nil} end,
          internal_state: nil
        },
        requests_in_flight: %{},
        queued_requests: [],
        max_retries: Keyword.get(args, :max_retries, @max_retries),
        max_queued: Keyword.get(args, :max_queued, @max_queued),
        task_supervisor: Keyword.fetch!(args, :task_supervisor)
      }

      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp http_client(args) do
    case Keyword.fetch(args, :http_client) do
      :error -> {:error, {:http_client, :missing}}
      # TODO validate arity
      {:ok, client} when is_function(client) -> {:ok, client}
      {:ok, _bad_client} -> {:error, {:http_client, :bad_client}}
    end
  end

  defp rate_limiter_config(args) do
    args |> Keyword.get(:rate_limiter, :default) |> RateLimiter.to_config()
  end

  @impl GenServer
  def handle_call(:resume, _from, state) do
    {:reply, :ok, do_resume(state)}
  end

  @impl GenServer
  def handle_call({:allocated?, ref}, _from, state) do
    {:reply, queued?(ref, state) || in_flight?(ref, state), state}
  end

  @impl GenServer
  def handle_call({:cancel, ref}, _from, state) do
    queued =
      Enum.reject(state.queued_requests, fn
        %PendingRequest{allocation: %AllocatedRequest{ref: ^ref}} -> true
        _ -> false
      end)

    {to_cancel, in_flight} =
      Enum.split_with(state.requests_in_flight, fn
        {_task_ref, %PendingRequest{allocation: %AllocatedRequest{ref: ^ref}}} -> true
        _ -> false
      end)

    Enum.each(to_cancel, fn {_, %PendingRequest{task: %Task{ref: ref, pid: pid}}} ->
      Process.demonitor(ref, [:flush])
      :ok = Task.Supervisor.terminate_child(state.task_supervisor, pid)
    end)

    state =
      state
      |> schedule_next_request(:unknown, :canceled)
      |> Map.replace!(:queued_requests, queued)
      |> Map.replace!(:requests_in_flight, Enum.into(in_flight, %{}))

    {:reply, :canceled, state}
  end

  @impl GenServer
  def handle_call(_, _from, %{status: {:suspended, _}} = state) do
    {:reply, {:error, :suspended}, state}
  end

  @impl GenServer
  def handle_call({:suspend, _reason, opts}, _from, state) do
    state =
      case Keyword.get(opts, :purge) do
        true -> purge_all_requests(state)
        _ -> state
      end

    {:reply, :ok, %{state | status: {:suspended, :infinity}}}
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
    allocated_request = %AllocatedRequest{
      ref: make_ref(),
      owner: pid,
      partition: state.key
    }

    pending_request = %PendingRequest{
      allocation: allocated_request,
      request: request
    }

    state =
      state
      |> Map.replace!(
        :queued_requests,
        state.queued_requests ++ [pending_request]
      )
      |> case do
        %{available: true} = state -> process_next_request(state)
        state -> state
      end
      |> Map.replace!(:available, false)

    {:reply, allocated_request, state}
  end

  @impl GenServer
  def handle_info(:auto_resume, %{status: {:suspended, :infinity}} = state), do: {:noreply, state}

  @impl GenServer
  def handle_info(:auto_resume, state), do: {:noreply, do_resume(state)}

  @impl GenServer
  def handle_info({task_ref, {req_duration, req_result}}, state) when is_reference(task_ref) do
    Process.demonitor(task_ref, [:flush])

    pending_request = Map.get(state.requests_in_flight, task_ref)
    %AllocatedRequest{ref: ref, owner: pid} = Map.get(pending_request, :allocation)

    state =
      state
      |> Map.replace!(:available, false)
      |> Map.replace!(:requests_in_flight, Map.delete(state.requests_in_flight, task_ref))

    {health, new_state} =
      state.health_checker.checker.(state.health_checker.internal_state, req_result)

    state = %{
      state
      | health_checker: Map.replace!(state.health_checker, :internal_state, new_state)
    }

    state =
      case health do
        # TODO NOW suspend at least as long as delay before next request
        {:suspend, duration} -> do_suspend(state, duration)
        :ok -> state
      end

    state =
      case req_result do
        {:ok, _} ->
          send(pid, {ref, req_result})
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

    {:noreply, schedule_next_request(state, req_duration, req_result)}
  end

  @impl GenServer
  def handle_info({:DOWN, task_ref, :process, _task_pid, {reason, _}}, state)
      when is_reference(task_ref) do
    %PendingRequest{allocation: %AllocatedRequest{ref: ref, owner: pid}} =
      Map.get(state.requests_in_flight, task_ref)

    Logger.error("Task failed", request_ref: ref)
    send(pid, {ref, {:error, {:task_failed, Map.get(reason, :message, "unknown")}}})
    state = %{state | requests_in_flight: Map.delete(state.requests_in_flight, task_ref)}

    {:noreply, process_next_request(state)}
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

  defp do_suspend(state, :infinity), do: %{state | status: {:suspended, :infinity}}

  defp do_suspend(state, duration) when is_integer(duration) and duration >= 0 do
    ref = Process.send_after(self(), :auto_resume, duration)
    %{state | status: {:suspended, ref}}
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

  defp schedule_next_request(%{status: {:suspended, _}} = state, _duration, _result), do: state

  defp schedule_next_request(state, duration, result) do
    {computed_delay, new_limiter_state} =
      state.rate_limiter.limiter.(
        duration_to_ms(duration),
        result,
        state.rate_limiter.internal_state
      )

    delay_before_next_request = clamp_delay(state.rate_limiter, computed_delay)
    Process.send_after(self(), :process_next_request, delay_before_next_request)

    %{state | rate_limiter: %{state.rate_limiter | internal_state: new_limiter_state}}
  end

  defp duration_to_ms(:unknown), do: :unknown
  defp duration_to_ms(duration), do: div(duration, 1_000)

  defp queued?(ref, state) when is_reference(ref),
    do: has_pending_request_with_ref?(state.queued_requests, ref)

  defp in_flight?(ref, state) when is_reference(ref),
    do: state.requests_in_flight |> Map.values() |> has_pending_request_with_ref?(ref)

  defp has_pending_request_with_ref?(items, ref) do
    find_pending_request_with_ref?(items, ref) != nil
  end

  defp find_pending_request_with_ref?(items, ref) do
    Enum.find(items, fn
      %PendingRequest{allocation: %AllocatedRequest{ref: ^ref}} -> true
      _ -> false
    end)
  end

  defp process_next_request(%{queued_requests: []} = state) do
    %{state | available: true}
  end

  defp process_next_request(%{queued_requests: q} = state) do
    [%PendingRequest{allocation: allocation} = next | t] = q
    %AllocatedRequest{owner: pid} = allocation

    if Process.alive?(pid) do
      %Task{ref: task_ref} =
        task =
        Task.Supervisor.async_nolink(state.task_supervisor, fn ->
          :timer.tc(fn -> state.http_client.(next.request) end)
        end)

      in_flight = Map.put(state.requests_in_flight, task_ref, %{next | task: task})

      %{state | requests_in_flight: in_flight, queued_requests: t}
    else
      process_next_request(%{state | queued_requests: t})
    end
  end

  defp clamp_delay(%{min_delay: min, max_delay: max}, delay) do
    delay |> max(min) |> min(max)
  end

  defp purge_all_requests(%{requests_in_flight: in_flight, queued_requests: queued} = state) do
    in_flight
    |> Map.values()
    |> Enum.each(&cancel_in_flight_request/1)

    Enum.each(queued, fn %PendingRequest{allocation: %AllocatedRequest{ref: ref, owner: pid}} ->
      send_cancelation(ref, pid)
    end)

    %{state | requests_in_flight: %{}, queued_requests: []}
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
