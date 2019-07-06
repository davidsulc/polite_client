defmodule PoliteClient.Client do
  @type t :: (request() -> result())
  @type result :: {:ok, response()} | {:error, failed_request()}

  # ideally, these would be opaque types but that results in
  # "opaque type xxx() is underspecified and therefore meaningless"
  # see https://github.com/elixir-lang/elixir/issues/1312
  @type response :: term()
  @type failed_request :: term()
  @type request :: term()

  def validate(client) when is_function(client, 1), do: {:ok, client}
  def validate(nil), do: {:error, :not_provided}
  def validate(_), do: {:error, :bad_client}

  @doc "Raises if the given argument doesn't conform to the `t:PoliteClient.Client.result/0` spec."
  @spec validate_result(result() | term()) :: :ok | no_return()

  def validate_result({:ok, _response}), do: :ok

  def validate_result({:error, _response}), do: :ok

  def validate_result(bad_result) do
    raise "expected client implementation to conform to `PoliteClient.Client.t()` and return " <>
            "a value matching `PoliteClient.Client.result()`, but got #{inspect(bad_result)}"
  end
end
