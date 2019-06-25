defmodule PoliteClient.Client do
  @moduledoc false

  use GenServer

  require Logger

  alias PoliteClient.{RateLimiter, Request}

  @max_queued 50

  @type http_client() ::
          (Request.t() -> {:ok, request_result :: term()} | {:error, request_result :: term()})

  def start_link(args) do
    # TODO verify args contains :http_client
    GenServer.start_link(__MODULE__, args, args)
  end

  @spec async_request(GenServer.name(), Request.t()) ::
          reference() | {:queued, reference()} | {:overloaded, :max_queued}
  def async_request(name, %Request{} = request) do
    GenServer.call(name, {:request, request})
  end

  @impl GenServer
  def init(args) do
    with {:ok, http_client} <- http_client(args),
         {:ok, rate_limiter_config} <- rate_limiter_config(args) do
      state = %{
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
  def handle_call({:request, request}, {pid, _}, %{available: true} = state) do
    %{http_client: c} = state
    ref = make_ref()
    in_flight = Map.put(state.requests_in_flight, request_task(c, request), {ref, pid})
    {:reply, ref, %{state | available: false, requests_in_flight: in_flight}}
  end

  @impl GenServer
  def handle_call({:request, request}, {pid, _}, %{available: false} = state) do
    ref = make_ref()

    if length(state.queued_requests) >= state.max_queued do
      {:reply, {:overloaded, :max_queued}, state}
    else
      {:reply, {:queued, ref},
       %{state | queued_requests: state.queued_requests ++ [{ref, pid, request}]}}
    end
  end

  @impl GenServer
  def handle_info({task_ref, {req_duration, req_result}}, state) when is_reference(task_ref) do
    Process.demonitor(task_ref, [:flush])

    {ref, pid} = Map.get(state.requests_in_flight, task_ref)
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
  def handle_info(:process_next_request, %{queued_requests: [{ref, pid, request} | t]} = state) do
    %{http_client: c} = state
    task_ref = request_task(c, request)
    in_flight = Map.put(state.requests_in_flight, task_ref, {ref, pid})

    {:noreply, %{state | requests_in_flight: in_flight, queued_requests: t}}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.error("Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # TODO implement terminate
  # => send cancellation notices for all queued requests
  # => shut down the tasks for all in-flight requests

  defp clamp_delay(%{min_delay: min, max_delay: max}, delay) do
    delay |> max(min) |> min(max)
  end

  @spec request_task(http_client :: http_client(), request :: Request.t()) :: reference()
  defp request_task(http_client, request) do
    %Task{ref: task_ref} = Task.async(fn -> :timer.tc(fn -> http_client.(request) end) end)
    task_ref
  end

  # TODO allow specifying http_client as a module/behaviour
end
