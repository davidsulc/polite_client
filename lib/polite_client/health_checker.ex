defmodule PoliteClient.HealthChecker do
  @moduledoc """
  Functionality related to health checks.
  """

  alias PoliteClient.ResponseMeta

  @type state :: %{
          checker: checker(),
          status: status(),
          initial_state: term(),
          internal_state: term()
        }

  @type status :: :ok | {:suspend, suspension_duration()}
  @type internal_state :: term()

  @typedoc """
  The checker function determining whether the remote host is healthy.

  Hosts in poor health shouldn't be queried for some time, to give them a chance to recover.

  This function is called for every response received from a successful request performed.
  To aid in determining whether the host is healthy or not, it may make use of an internal state which is
  maintained exclusively for the checker function.

  Every time it is called, the function will receive the current `t:PoliteClient.HealthChecker.internal_state/0`
  and the `t:PoliteClient.ResponseMeta.t/0` corresponding to the request result.

  The function should return a tuple containing the new `t:PoliteClient.HealthChecker.status/0` for the host
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

  @type suspension_duration() :: non_neg_integer() | :infinity

  @spec to_config(config :: map()) :: {:ok, state()}
  def to_config(%{} = config), do: {:ok, config}

  @spec to_config(:default) :: {:ok, state()}
  def to_config(:default),
    do: to_config(fn nil, _ -> {:ok, nil} end, nil)

  @spec to_config(checker(), term()) :: {:ok, state()}

  def to_config(fun, initial_state) do
    config = %{
      checker: fun,
      status: :ok,
      initial_state: initial_state,
      internal_state: initial_state
    }

    {:ok, config}
  end

  def update_state(
        %{checker: checker, internal_state: internal_state} = state,
        %ResponseMeta{} = response_meta
      ) do
    {status, new_state} = checker.(internal_state, response_meta)

    %{state | internal_state: new_state, status: status}
  end

  @spec reset_internal_state(state :: state()) :: state()
  def reset_internal_state(%{initial_state: i} = state), do: %{state | internal_state: i}
end
