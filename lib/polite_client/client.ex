defmodule PoliteClient.Client do
  @moduledoc false

  use GenServer

  require Logger

  alias PoliteClient.Request

  @max_queued 50
  @min_delay 1_000
  @max_delay 120_000

  @type http_client() ::
          (Request.t() -> {:ok, request_result :: term()} | {:error, request_result :: term()})
  @type rate_limiter() ::
          (request_duration :: non_neg_integer(),
           request_result :: term(),
           limiter_state :: term() ->
             {next_request_delay :: non_neg_integer(), new_limiter_state :: term()})

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
    rate_limiter_config =
      args |> Keyword.get(:rate_limiter, {:constant, @min_delay}) |> rate_limiter_config()

    state = %{
      # indicates whether a request can be made (given rate limiting): it's not enough
      # for the queue to be empty (b/c the last request may be been made too recently)
      available: true,
      http_client: Keyword.fetch!(args, :http_client),
      rate_limiter: rate_limiter_config,
      requests_in_flight: %{},
      queued_requests: [],
      max_queued: Keyword.get(args, :max_queued, @max_queued)
    }

    {:ok, state}
  end

  @spec rate_limiter_config({atom() | rate_limiter(), term(), Keyword.t()}) :: map()

  defp rate_limiter_config({:constant, delay, opts}) do
    opts =
      opts
      |> Keyword.put_new(:min_delay, delay)
      |> Keyword.put_new(:max_delay, delay)

    rate_limiter_config({fn _duration, _request_result, nil -> {delay, nil} end, nil, opts})
  end

  defp rate_limiter_config({:factor, factor, opts}) do
    rate_limiter_config(
      {fn duration, _request_result, nil -> {round(duration * factor), nil} end, nil, opts}
    )
  end

  defp rate_limiter_config({fun, initial_state, opts}) do
    # TODO validate delays: must be integers
    %{
      limiter: fun,
      internal_state: initial_state,
      min_delay: Keyword.get(opts, :min_delay, @min_delay),
      max_delay: Keyword.get(opts, :max_delay, @max_delay)
    }
  end

  @spec rate_limiter_config({atom() | rate_limiter(), term()}) :: map()

  defp rate_limiter_config({limiter, value}) when is_atom(limiter) or is_function(limiter, 3),
    do: rate_limiter_config({limiter, value, []})

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
