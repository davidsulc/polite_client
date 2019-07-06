defmodule PoliteClient.Partition.State do
  @moduledoc false

  alias PoliteClient.{AllocatedRequest, Client, HealthChecker, RateLimiter, ResponseMeta}
  alias PoliteClient.Partition.PendingRequest

  @type t :: %__MODULE__{
          key: String.t(),
          client: Client.t(),
          health_checker: HealthChecker.state(),
          rate_limiter: RateLimiter.state(),
          max_retries: non_neg_integer(),
          max_queued: non_neg_integer(),
          task_supervisor: GenServer.name(),
          status: status(),
          available: boolean(),
          in_flight_requests: %{required(reference()) => PendingRequest.t()},
          queued_requests: [PendingRequest.t()]
        }

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
         {:ok, rate_limiter_config} <- rate_limiter_config(args),
         {:ok, health_checker_config} <- health_checker_config(args) do
      state = %__MODULE__{
        key: Keyword.fetch!(args, :key),
        status: :active,
        available: true,
        client: client,
        rate_limiter: rate_limiter_config,
        health_checker: health_checker_config,
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

  defp health_checker_config(args) do
    args |> Keyword.get(:health_checker, :default) |> HealthChecker.to_config()
  end

  @spec set_status(state :: t(), status :: status()) :: t()
  def set_status(%__MODULE__{} = state, status), do: %{state | status: status}

  @spec set_available(t()) :: t()
  def set_available(%__MODULE__{} = state) do
    %{state | available: true}
  end

  @spec set_unavailable(t()) :: t()
  def set_unavailable(%__MODULE__{} = state) do
    %{state | available: false}
  end

  @spec suspend(state :: t(), duration :: :infinity | reference()) :: t()
  def suspend(%__MODULE__{} = state, ref \\ :infinity)
      when is_reference(ref) or ref == :infinity do
    set_status(state, {:suspended, ref})
  end

  @spec enqueue(state :: t(), new_request :: PendingRequest.t()) :: t()
  def enqueue(%__MODULE__{queued_requests: q} = state, %PendingRequest{} = new_request) do
    %{state | queued_requests: q ++ [new_request]}
  end

  @spec queued?(state :: t(), ref :: reference()) :: boolean()
  def queued?(%__MODULE__{queued_requests: q}, ref) when is_reference(ref),
    do: has_pending_request_with_ref?(q, ref)

  @spec set_queued_requests(state :: t(), request :: PendingRequest.t()) :: t()
  def set_queued_requests(%__MODULE__{} = state, q) do
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

  def update_health_checker_state(%__MODULE__{} = state, %ResponseMeta{} = response_meta) do
    new_health_checker_state =
      state
      |> get_health_checker_state()
      |> HealthChecker.update_state(response_meta)

    set_health_checker_state(state, new_health_checker_state)
  end

  defp get_health_checker_state(%__MODULE__{health_checker: x}), do: x

  defp set_health_checker_state(%__MODULE__{} = state, x), do: %{state | health_checker: x}

  def check_health(%__MODULE__{} = state), do: state.health_checker.status

  def reset_health_checker_internal_state(%__MODULE__{} = state) do
    new_health_checker_state =
      state |> get_health_checker_state() |> HealthChecker.reset_internal_state()

    set_health_checker_state(state, new_health_checker_state)
  end

  def update_rate_limiter_state(%__MODULE__{} = state, %ResponseMeta{} = response_meta) do
    new_rate_limiter_state =
      state
      |> get_rate_limiter_state()
      |> RateLimiter.update_state(response_meta)

    set_rate_limiter_state(state, new_rate_limiter_state)
  end

  defp get_rate_limiter_state(%__MODULE__{rate_limiter: x}), do: x

  defp set_rate_limiter_state(%__MODULE__{} = state, x), do: %{state | rate_limiter: x}

  def reset_rate_limiter_internal_state(%__MODULE__{} = state) do
    new_rate_limiter_state =
      state |> get_rate_limiter_state() |> RateLimiter.reset_internal_state()

    set_rate_limiter_state(state, new_rate_limiter_state)
  end

  def get_current_request_delay(%__MODULE__{} = state) do
    state
    |> Map.get(:rate_limiter)
    |> Map.get(:current_delay)
  end
end
