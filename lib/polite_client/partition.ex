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
            attempts: non_neg_integer()
          }

    @enforce_keys [:allocation, :request]
    defstruct allocation: nil, request: nil, task: nil, attempts: 0
  end

  @max_queued 50
  @task_attempts 3

  @type http_client() ::
          (Request.t() -> {:ok, request_result :: term()} | {:error, request_result :: term()})

  def start_link(args) do
    # TODO verify args contains :http_client
    GenServer.start_link(__MODULE__, args, args)
  end

  @spec async_request(GenServer.name(), Request.t()) ::
          AllocatedRequest.t() | {:error, :max_queued | :suspended}
  def async_request(name, %Request{} = request) do
    GenServer.call(name, {:request, request})
  end

  @spec allocated?(GenServe.name(), reference()) :: boolean()
  def allocated?(name, ref) do
    GenServer.call(name, {:allocated?, ref})
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
        requests_in_flight: %{},
        queued_requests: [],
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
  def handle_call(:resume, _from, %{status: :suspended} = state) do
    {:reply, :ok, %{state | status: :active}}
  end

  @impl GenServer
  def handle_call({:allocated?, ref}, _from, state) do
    {:reply, queued?(ref, state) || in_flight?(ref, state), state}
  end

  @impl GenServer
  def handle_call(_, _from, %{status: :suspended} = state) do
    {:reply, {:error, :suspended}, state}
  end

  @impl GenServer
  def handle_call({:suspend, _reason, opts}, _from, state) do
    state =
      case Keyword.get(opts, :purge) do
        true -> purge_all_requests(state)
        _ -> state
      end

    {:reply, :ok, %{state | status: :suspended}}
  end

  @impl GenServer
  def handle_call({:request, request}, {pid, _}, state) do
    if length(state.queued_requests) >= state.max_queued do
      {:reply, {:error, :max_queued}, state}
    else
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
  end

  @impl GenServer
  def handle_info({task_ref, {req_duration, req_result}}, state) when is_reference(task_ref) do
    Process.demonitor(task_ref, [:flush])

    %AllocatedRequest{ref: ref, owner: pid} =
      state.requests_in_flight
      |> Map.get(task_ref)
      |> Map.get(:allocation)

    send(pid, {ref, req_result})

    req_duration_in_ms = div(req_duration, 1_000)

    log_meta = [request_ref: ref]
    Logger.debug("Request duration: #{req_duration_in_ms}", log_meta)

    {computed_delay, new_limiter_state} =
      state.rate_limiter.limiter.(
        req_duration_in_ms,
        req_result,
        state.rate_limiter.internal_state
      )

    Logger.debug(
      "Request delay computed by rate limiter: #{computed_delay}",
      log_meta
    )

    delay_before_next_request = clamp_delay(state.rate_limiter, computed_delay)
    Logger.debug("Clamped request delay: #{delay_before_next_request}", log_meta)
    Process.send_after(self(), :process_next_request, delay_before_next_request)

    state = %{
      state
      | available: false,
        requests_in_flight: Map.delete(state.requests_in_flight, task_ref),
        rate_limiter: %{state.rate_limiter | internal_state: new_limiter_state}
    }

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, task_ref, :process, _task_pid, {reason, _}}, state)
      when is_reference(task_ref) do
    %PendingRequest{
      allocation: %AllocatedRequest{ref: ref, owner: pid},
      attempts: attempts
    } = pending_req = Map.get(state.requests_in_flight, task_ref)

    state =
      if attempts > @task_attempts do
        Logger.error("Task failed", request_ref: ref)

        send(pid, {ref, {:error, {:task_failed, Map.get(reason, :message, "unknown")}}})

        state
      else
        Logger.debug("Retrying request #{inspect(ref)}")

        %{
          state
          | queued_requests: [%{pending_req | attempts: attempts + 1} | state.queued_requests]
        }
      end

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

  defp queued?(ref, state) when is_reference(ref),
    do: has_pending_request_with_ref?(state.queued_requests, ref)

  defp in_flight?(ref, state) when is_reference(ref),
    do: has_pending_request_with_ref?(state.requests_in_flight, ref)

  defp has_pending_request_with_ref?(items, ref) do
    Enum.any?(items, fn
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

      in_flight =
        Map.put(state.requests_in_flight, task_ref, %{
          next
          | task: task,
            attempts: next.attempts + 1
        })

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
