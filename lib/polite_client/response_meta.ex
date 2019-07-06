defmodule PoliteClient.ResponseMeta do
  alias PoliteClient.Client

  @type t :: %__MODULE__{
          result: Client.result(),
          # TODO document: duration is in microseconds
          duration: non_neg_integer()
        }

  @enforce_keys [:result, :duration]
  defstruct [:result, :duration]
end
