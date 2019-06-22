defmodule PoliteClient.Request do
  defstruct [
    :uri,
    :headers,
    :body,
    :opts,
    method: :get
  ]
end
