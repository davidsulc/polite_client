defmodule PoliteClient.Client do
  @type t :: (request() -> result())
  @type result :: {:ok, response()} | {:error, failed_request()}

  # ideally, these would be opaque types but that results in
  # "opaque type xxx() is underspecified and therefore meaningless"
  # see https://github.com/elixir-lang/elixir/issues/1312
  @type response :: term()
  @type failed_request :: term()
  @type request :: term()
end
