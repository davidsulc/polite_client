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

  @spec to_config(:default) :: {:ok, state()}
  def to_config(:default),
    do:
      {:ok,
       %{
         checker: fn nil, _ -> {:ok, nil} end,
         status: :ok,
         internal_state: nil
       }}

  @spec to_config(checker(), term()) :: {:ok, state()}

  def to_config(fun, initial_state) do
    config = %{
      checker: fun,
      status: :ok,
      internal_state: initial_state
    }

    {:ok, config}
  end
end
