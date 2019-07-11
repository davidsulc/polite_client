defmodule PoliteClient.HealthChecker do
  @moduledoc """
  Functionality related to health checks.

  In order to avoid overwhelming a remote host that is struggling (e.g. having requests
  time out, taking too long to respond), the PoliteClient will suspend a partition whose
  health checks fail.

  When a partition is suspended, no requests to the remote host will be performed.

  If the suspension is temporary (given a finite duration), the partition will return to
  active state on its own. On the other hand, if the suspension is permanent, the partition
  will require a manual intervention (via `PoliteClient.resume/1`) to return to the active state.

  When resuming automatically from suspension the health checker and rate limiter states are
  preserved: the next request will NOT be triggered immediately (whereas it would be on manual
  resume with `PoliteClient.resume/1`).
  """

  alias PoliteClient.ResponseMeta

  @typedoc "The healther checker configuration."
  @type config :: %{
          checker: checker(),
          initial_state: term()
        }

  @typedoc "The health checker's state."
  @opaque state :: %{
            checker: checker(),
            status: status(),
            initial_state: term(),
            internal_state: term()
          }

  @typedoc """
  The status indicating whether the partition is currently healthy, or if it should be suspended.
  """
  @type status :: :ok | {:suspend, suspension_duration()}

  @typedoc """
  The (opaque) internal state that the `t:PoliteClient.HealthChecker.checker/0` receives and
  updates.
  """
  @type internal_state :: term()

  @typedoc """
  The checker function determining whether the remote host is healthy.

  Hosts in poor health shouldn't be queried for some time, to give them a chance to recover.

  This function is called for every response received from a successful request performed.
  To aid in determining whether the host is healthy or not, it may make use of an internal state which is
  maintained exclusively for the checker function.

  Every time it is called, the function will receive the current `t:PoliteClient.HealthChecker.internal_state/0`
  and the `t:PoliteClient.ResponseMeta.t/0` corresponding to the request result.

  The function should return a tuple containing the new `t:PoliteClient.HealthChecker.status/0` for the partition
  and the updated `t:PoliteClient.HealthChecker.internal_state/0`. The `status` must be one of:

  - `:ok` if the host is healthy
  - `{:suspend, duration}` if the host shouldn't be contacted for `duration` milliseconds. After the given duration,
       the host may be contacted again (which is handled by the library)
  - `{:suspend, :infinity}` if the host shouldn't be contacted until the partition is resumed manually via
      `PoliteClient.resume/1`

  The new `t:PoliteClient.HealthChecker.internal_state/0` value returned in the tuple will be transparently updated
  and provided to the function on the next call.

  Note that while failing request results should likely be taked in to account when making host health determinations,
  you may want to also consider successful requests such as HTTP 5xx status codes, or HTTP 429 "Too Many Requests".
  and degrade the host health evaluation accordingly. For example, you may decide that if more than half of the recent
  requests resulted in a 504 "Gateway Timeout" error, you should suspend for 15 mins, but upon receiving a single
  429 "Too Many Requests" reply you immediately suspend for 5 minutes.
  """
  @type checker() ::
          (internal_state :: internal_state(), response_meta :: ResponseMeta.t() ->
             {status(), new_internal_state :: internal_state()})

  @typedoc """
  A duration for which to suspend the related partition.

  The partition will "self heal" and resume normal operations once the duration (in milliseconds) runs out.
  If the duration is `:infinity`, the partition will not resume operations on itself and must be reactived
  manually (typically via `PoliteClient.resume/1`.
  """
  @type suspension_duration() :: non_neg_integer() | :infinity

  @doc "Returns a health checker configuration that always considers the partition to be in a healthy state."
  @spec default_config() :: {:ok, config()}
  def default_config() do
    {:ok, config} = config(fn nil, _ -> {:ok, nil} end, nil)
    config
  end

  @doc """
  Returns a health checker configuration.

  The configuration will use the `checker_function` to determine the partition's health after every request,
  and will initialize its internal state with `initial_state`.

  The health checker's internal state will also be reinitialized to the value of `initial_state` when a partition
  is manually resumed.
  """
  @spec config(checker_function :: checker(), initial_state :: internal_state()) ::
          {:ok, config()}
  def config(checker_function, initial_state) when is_function(checker_function, 2) do
    config = %{
      checker: checker_function,
      initial_state: initial_state
    }

    {:ok, config}
  end

  @doc "Returns a boolean indicating whether the given argument is a valid internal state."
  @spec config_valid?(term()) :: boolean()

  def config_valid?(%{checker: checker, initial_state: _}) do
    is_function(checker, 2)
  end

  def config_valid?(_config), do: false

  @doc false
  @spec to_state(config()) :: state()
  def to_state(%{checker: checker, initial_state: initial_state}) do
    %{
      checker: checker,
      status: :ok,
      initial_state: initial_state,
      internal_state: initial_state
    }
  end

  @doc """
  Updates the internal state.

  Executes the `t:PoliteClient.HealthChecker.checker/0` function, and uses its return value to update
  the internal state.
  """
  @spec update_state(state :: state(), response_meta :: ResponseMeta.t()) :: state()
  def update_state(
        %{checker: checker, internal_state: internal_state} = state,
        %ResponseMeta{} = response_meta
      ) do
    # TODO raise on bad return value
    {status, new_state} = checker.(internal_state, response_meta)

    %{state | internal_state: new_state, status: status}
  end

  @doc "Resets the internal state to the `t:PoliteClient.HealthChecker.internal_state/0` initially provided."
  @spec reset_internal_state(state :: state()) :: state()
  def reset_internal_state(%{initial_state: i} = state), do: %{state | internal_state: i}
end
