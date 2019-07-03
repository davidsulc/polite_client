defmodule PoliteClient.HealthChecker do
  @type state :: %{
          checker: checker(),
          status: status(),
          internal_state: term()
        }

  @type status :: :ok | {:suspend, suspension_duration()}

  @type checker() ::
          (internal_state :: term(), request_result :: term() | :canceled ->
             {:ok | {:suspend, suspension_duration()}, new_internal_state :: term()})

  @type suspension_duration() :: non_neg_integer() | :infinity

  # TODO use struct?

  @spec to_config(atom()) :: {:ok, state()}
  def to_config(:default),
    do:
      {:ok,
       %{
         checker: fn nil, _ -> {:ok, nil} end,
         status: :ok,
         internal_state: nil
       }}
end
