defmodule PoliteClient.Client do
  @moduledoc """
  Specification of the client functionality the PoliteClient will use to make requests.

  The client provides an abstraction to make requests on the caller's behalf. It will
  receive a request, and will return a normalized `{:ok, ...}` or `{:error, ...}`
  response. The request itself is treated as opaque by the PoliteClient: only the
  `t:PoliteClient.Client.t/0` itself must know how to handle the request argument in order to
  make the request itself.
  """

  @typedoc """
  The client abstraction specification

  It receives an opaque request parameter, and returns a standardized tagged tuple as a result.
  """
  @type t :: (request() -> result())

  @typedoc "The result returned by the client `t:t/0` abstraction."
  @type result :: {:ok, response()} | {:error, failed_request()}

  # ideally, these would be opaque types but that results in
  # "opaque type xxx() is underspecified and therefore meaningless"
  # see https://github.com/elixir-lang/elixir/issues/1312
  #
  @typedoc "The (opaque) response received after making a request."
  @type response :: term()

  @typedoc "The (opaque) result of a failed request (e.g. network unavailable)"
  @type failed_request :: term()

  @typedoc "The (opaque) value representing a request to be made."
  @type request :: term()

  @doc """
  Validate whether the given value appears to be a valid client function.

  This function may return `{:ok, ...}` even if the client isn't valid.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, :not_provided | :bad_client}
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
