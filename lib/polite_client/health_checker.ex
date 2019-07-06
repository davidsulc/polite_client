defmodule PoliteClient.HealthChecker do
  alias PoliteClient.ResponseMeta

  @type state :: %{
          checker: checker(),
          status: status(),
          internal_state: term()
        }

  @type status :: :ok | {:suspend, suspension_duration()}
  @type internal_state :: term()

  @type checker() ::
          (internal_state :: internal_state(), response_meta :: ResponseMeta.t() ->
             {:ok | {:suspend, suspension_duration()}, new_internal_state :: internal_state()})

  @type suspension_duration() :: non_neg_integer() | :infinity

  # TODO use struct?

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
  # def reset_internal_state(%{initial_state: i} = state), do: %{state | internal_state: i}
  def reset_internal_state(%{initial_state: i} = state) do
    IO.puts("resetting internal state")
    %{state | internal_state: i}
  end
end
