defmodule PoliteClient.HealthChecker do
  @type t :: %{
          checker: checker(),
          internal_state: term()
        }

  @type checker() ::
          (internal_state :: term(), request_result :: term() | :canceled ->
             {:ok | {:suspend, suspension_duration()}, new_internal_state :: term()})

  @type suspension_duration() :: non_neg_integer() | :infinity

  @spec to_config(atom()) :: {:ok, t()}
  def to_config(:default),
    do: %{
      checker: fn nil, _ -> {:ok, nil} end,
      internal_state: nil
    }
end
