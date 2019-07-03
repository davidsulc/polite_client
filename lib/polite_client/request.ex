defmodule PoliteClient.Request do
  # TODO there's no reason to force a struct here:
  # the provided client makes the request and returns the necessary
  # info in a known format => change this to be opaque (as a term())
  @type t() :: %__MODULE__{}

  defstruct [
    :uri,
    :headers,
    :body,
    :opts,
    method: :get
  ]
end
