defmodule PoliteClient.Partition do
  @moduledoc false

  use GenServer

  require Logger

  alias PoliteClient.{AllocatedRequest, RateLimiter, Request}

  @max_queued 50

  @type http_client() ::
          (Request.t() -> {:ok, request_result :: term()} | {:error, request_result :: term()})

  def start_link(args) do
    # TODO verify args contains :http_client
    GenServer.start_link(__MODULE__, args, args)
  end

  @spec async_request(GenServer.name(), Request.t()) ::
          reference() | {:queued, reference()} | {:error, :max_queued}
  def async_request(name, %Request{} = request) do
    GenServer.call(name, {:request, request})
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
        status: :active,
        # indicates whether a request can be made (given rate limiting): it's not enough
        # for the queue to be empty (b/c the last request may be been made too recently)
        available: true,
        http_client: http_client,
        rate_limiter: rate_limiter_config,
        requests_in_flight: %{},
        queued_requests: [],
        max_queued: Keyword.get(args, :max_queued, @max_queued)
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
      allocated_request = %AllocatedRequest{ref: make_ref(), owner: pid}

      state =
        state
        |> Map.replace!(:queued_requests, state.queued_requests ++ [{allocated_request, request}])
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

    %AllocatedRequest{ref: ref, owner: pid} = Map.get(state.requests_in_flight, task_ref)
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
  def handle_info(:process_next_request, %{queued_requests: []} = state) do
    {:noreply, %{state | available: true}}
  end

  @impl GenServer
  def handle_info(:process_next_request, %{queued_requests: [_ | _]} = state) do
    {:noreply, process_next_request(state)}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.error("Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state), do: purge_all_requests(state)

  defp process_next_request(%{queued_requests: q} = state) do
    [{%AllocatedRequest{} = allocated_request, request} | t] = q
    %Task{ref: task_ref} = request_task(state.http_client, request)
    in_flight = Map.put(state.requests_in_flight, task_ref, allocated_request)
    %{state | requests_in_flight: in_flight, queued_requests: t}
  end

  defp clamp_delay(%{min_delay: min, max_delay: max}, delay) do
    delay |> max(min) |> min(max)
  end

  @spec request_task(http_client :: http_client(), request :: Request.t()) :: reference()
  defp request_task(http_client, request) do
    Task.async(fn -> :timer.tc(fn -> http_client.(request) end) end)
  end

  defp purge_all_requests(%{requests_in_flight: in_flight, queued_requests: queued} = state) do
    in_flight
    |> Map.values()
    |> Enum.each(&cancel_in_flight_request/1)

    Enum.each(queued, fn {ref, pid, _request} -> send_cancelation(ref, pid) end)

    %{state | requests_in_flight: %{}, queued_requests: []}
  end

  defp cancel_in_flight_request({ref, pid, task}) do
    case Task.shutdown(task) do
      {:ok, {_duration, result}} -> send(pid, {ref, result})
      _res -> send(pid, {ref, :canceled})
    end
  end

  defp send_cancelation(ref, pid), do: send(pid, {ref, :canceled})
end
