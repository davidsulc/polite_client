defmodule PoliteClient.ResponseMeta do
  @moduledoc """
  Struct containing information regarding a successful request.

  Instances of this struct are used to update the `t:PoliteClient.RateLimiter.internal_state/0` and
  `t:PoliteClient.HealthChecker.internal_state/0` states.
  """

  alias PoliteClient.Client

  @typedoc """
  The ResponseMeta struct.

  See `%PoliteClient.ResponseMeta{}` for more information about each field of the structure.
  """
  @type t :: %__MODULE__{
          result: Client.result(),
          duration: non_neg_integer()
        }

  @doc """
  Contains information about a successful request.

  It contains these fields:

  * `:result` - the result of the request, as given by the `t:PoliteClient.Client.t/0` that
      made it
  * `:duration` - the duration of the request in microseconds
  """
  @enforce_keys [:result, :duration]
  defstruct [:result, :duration]
end
