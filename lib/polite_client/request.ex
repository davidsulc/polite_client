defmodule PoliteClient.Request do
  @type t() :: %__MODULE__{}

  defstruct [
    :uri,
    :headers,
    :body,
    :opts,
    method: :get
  ]
end
