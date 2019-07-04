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
    @moduledoc false

    alias PoliteClient.AllocatedRequest

    @type t :: %__MODULE__{
            allocation: AllocatedRequest.t(),
            request: Request.t(),
            task: nil | Task.t(),
            retries: non_neg_integer()
          }

    @enforce_keys [:allocation, :request]
    defstruct allocation: nil, request: nil, task: nil, retries: 0

    @spec get_allocation(t()) :: AllocatedRequest.t()
    def get_allocation(%__MODULE__{allocation: allocation}), do: allocation

    @spec for_allocation?(pending_request :: t(), allocation :: AllocatedRequest.t()) :: boolean()
    def for_allocation?(%PendingRequest{} = pending_request, %AllocatedRequest{} = allocation) do
      pending_request
      |> get_allocation()
      |> AllocatedRequest.same?(allocation)
    end
  end

  defmodule State do
    @moduledoc false

    alias PoliteClient.Partition.PendingRequest

    @type t :: %__MODULE__{
            key: String.t(),
            client: client(),
            health_checker: PoliteClient.HealthChecker.state(),
            rate_limiter: PoliteClient.RateLimiter.state(),
            max_retries: non_neg_integer(),
            max_queued: non_neg_integer(),
            task_supervisor: GenServer.name(),
            status: status(),
            available: boolean(),
            in_flight_requests: %{required(reference()) => PendingRequest.t()},
            queued_requests: [PendingRequest.t()]
          }

    @type client() ::
            (Request.t() -> {:ok, request_result :: term()} | {:error, request_result :: term()})

    @type status :: :active | {:suspended, :infinity | reference()}

    @max_queued 50
    @max_retries 3

    @enforce_keys [
      :key,
      :client,
      :health_checker,
      :rate_limiter,
      :max_retries,
      :max_queued,
      :task_supervisor,
      :status,
      :available,
      :in_flight_requests,
      :queued_requests
    ]
    defstruct [
      :key,
      :client,
      :health_checker,
      :rate_limiter,
      :max_retries,
      :max_queued,
      :task_supervisor,
      status: :active,
      # indicates whether a request can be made (given rate limiting): it's not enough
      # for the queue to be empty (b/c the last request may have been made too recently)
      available: true,
      in_flight_requests: %{},
      queued_requests: []
    ]

    @spec from_keywords(Keyword.t()) :: {:ok, t()} | {:error, reason :: term()}
    def from_keywords(args) when is_list(args) do
      with {:ok, client} <- get_client(args),
           {:ok, rate_limiter_config} <- rate_limiter_config(args) do
        state = %State{
          key: Keyword.fetch!(args, :key),
          status: :active,
          available: true,
          client: client,
          rate_limiter: rate_limiter_config,
          # TODO NOW
          health_checker: %{
            status: :ok,
            checker: fn nil, _ref -> {{:suspend, 3_000}, nil} end,
            internal_state: nil
          },
          in_flight_requests: %{},
          queued_requests: [],
          max_retries: Keyword.get(args, :max_retries, @max_retries),
          max_queued: Keyword.get(args, :max_queued, @max_queued),
          task_supervisor: Keyword.fetch!(args, :task_supervisor)
        }

        {:ok, state}
      else
        {:error, _reason} = error -> error
      end
    end

    defp get_client(args) do
      case Keyword.fetch(args, :client) do
        :error -> {:error, {:client, :not_provided}}
        {:ok, client} when is_function(client, 1) -> {:ok, client}
        {:ok, _bad_client} -> {:error, {:client, :bad_client}}
      end
    end

    defp rate_limiter_config(args) do
      args |> Keyword.get(:rate_limiter, :default) |> RateLimiter.to_config()
    end

    @spec set_unavailable(t()) :: t()
    def set_unavailable(%__MODULE__{} = state) do
      %{state | available: false}
    end

    @spec suspend(state :: t(), duration :: :infinity | reference()) :: t()
    def suspend(%__MODULE__{} = state, ref \\ :infinity)
        when is_reference(ref) or ref == :infinity do
      %{state | status: {:suspended, ref}}
    end

    @spec enqueue(state :: t(), new_request :: PendingRequest.t()) :: t()
    def enqueue(%__MODULE__{queued_requests: q} = state, %PendingRequest{} = new_request) do
      %{state | queued_requests: q ++ [new_request]}
    end

    @spec queued?(state :: t(), ref :: reference()) :: boolean()
    def queued?(%__MODULE__{queued_requests: q}, ref) when is_reference(ref),
      do: has_pending_request_with_ref?(q, ref)

    @spec set_queued_requests(state :: t(), request :: PendingRequest.t()) :: t()
    def set_queued_requests(%State{} = state, q) do
      %{state | queued_requests: q}
    end

    @spec delete_queued_requests_by_allocation(state :: t(), allocation :: AllocatedRequest.t()) ::
            t()
    def delete_queued_requests_by_allocation(
          %__MODULE__{} = state,
          %AllocatedRequest{} = allocation
        ) do
      %{
        state
        | queued_requests:
            Enum.reject(state.queued_requests, &PendingRequest.for_allocation?(&1, allocation))
      }
    end

    @spec in_flight?(state :: t(), ref :: reference()) :: boolean()
    def in_flight?(%__MODULE__{in_flight_requests: in_flight}, ref)
        when is_reference(ref),
        do: in_flight |> Map.values() |> has_pending_request_with_ref?(ref)

    @spec has_pending_request_with_ref?(items :: [PendingRequest.t()], ref :: reference()) ::
            boolean()
    defp has_pending_request_with_ref?(items, ref) do
      find_pending_request_with_ref?(items, ref) != nil
    end

    @spec find_pending_request_with_ref?(items :: [PendingRequest.t()], ref :: reference()) ::
            PendingRequest.t()
    defp find_pending_request_with_ref?(items, ref) do
      Enum.find(items, fn
        %PendingRequest{allocation: %{ref: ^ref}} -> true
        _ -> false
      end)
    end

    def get_in_flight_request(%__MODULE__{in_flight_requests: in_flight}, task_ref),
      do: Map.get(in_flight, task_ref)

    def add_in_flight_request(
          %__MODULE__{in_flight_requests: in_flight} = state,
          task_ref,
          %PendingRequest{} = request
        )
        when is_reference(task_ref) do
      %{state | in_flight_requests: Map.put(in_flight, task_ref, request)}
    end

    def delete_in_flight_request(%__MODULE__{in_flight_requests: in_flight} = state, task_ref),
      do: %{state | in_flight_requests: Map.delete(in_flight, task_ref)}

    def set_in_flight_requests(%__MODULE__{} = state, in_flight),
      do: %{state | in_flight_requests: in_flight}

    def update_health_checker_state(%__MODULE__{} = state, req_result) do
      {status, new_state} =
        state.health_checker.checker.(state.health_checker.internal_state, req_result)

      health_checker =
        state
        |> Map.get(:health_checker)
        |> Map.replace!(:internal_state, new_state)
        |> Map.replace!(:status, status)

      %{state | health_checker: health_checker}
    end

    def check_health(%__MODULE__{} = state), do: state.health_checker.status

    def update_rate_limiter_state(
          %__MODULE__{rate_limiter: %{limiter: limiter, internal_state: internal_state}} = state,
          req_result,
          duration
        ) do
      {computed_delay, new_state} =
        limiter.(
          duration,
          req_result,
          internal_state
        )

      rate_limiter =
        state
        |> Map.get(:rate_limiter)
        |> Map.replace!(:internal_state, new_state)
        |> Map.replace!(:request_delay, clamp_delay(state.rate_limiter, computed_delay))

      %{state | rate_limiter: rate_limiter}
    end

    defp clamp_delay(%{min_delay: min, max_delay: max}, delay), do: delay |> max(min) |> min(max)

    def get_request_delay(%__MODULE__{} = state) do
      state
      |> Map.get(:rate_limiter)
      |> Map.get(:request_delay)
    end
  end

  def start_link(args) do
    # TODO verify args contains :client
    GenServer.start_link(__MODULE__, args, args)
  end

  @spec async_request(GenServer.name(), Request.t()) ::
          AllocatedRequest.t()
          | {:error, :max_queued | :suspended | {:retries_exhausted, last_error :: term()}}
  def async_request(name, %Request{} = request) do
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
  def handle_info({task_ref, {req_duration, req_result}}, state) when is_reference(task_ref) do
    Process.demonitor(task_ref, [:flush])

    state =
      state
      |> State.set_unavailable()
      |> suspend_if_not_healthy(req_result)
      |> handle_request_result(req_result, task_ref)
      |> State.delete_in_flight_request(task_ref)
      # TODO
      |> State.update_rate_limiter_state(req_result, req_duration)
      |> schedule_next_request()

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, task_ref, :process, _task_pid, {reason, _}}, state)
      when is_reference(task_ref) do
    %AllocatedRequest{ref: ref, owner: pid} =
      state
      |> State.get_in_flight_request(task_ref)
      |> PendingRequest.get_allocation()

    Logger.error("Task failed", request_ref: ref)
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

  defp suspend_if_not_healthy(%State{} = state, req_result) do
    state
    |> State.update_health_checker_state(req_result)
    |> State.check_health()
    |> case do
      {:suspend, :infinity} ->
        State.suspend(state, :infinity)

      # TODO NOW suspend at least as long as delay before next request
      {:suspend, duration} ->
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

  defp handle_request_result(state, req_result, task_ref) do
    pending_request = State.get_in_flight_request(state, task_ref)
    %AllocatedRequest{ref: ref, owner: pid} = PendingRequest.get_allocation(pending_request)

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
  end

  defp schedule_next_request(%{status: {:suspended, _}} = state), do: state

  defp schedule_next_request(state) do
    Process.send_after(self(), :process_next_request, State.get_request_delay(state))
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
            :timer.tc(fn -> state.client.(next.request) end)
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
