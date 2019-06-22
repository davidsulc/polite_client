defmodule PoliteClient do
  @moduledoc """
  Documentation for PoliteClient.
  """

  @doc """
  Hello world.

  ## Examples

      iex> PoliteClient.hello()
      :world

  """
  def hello do
    :world
  end

  defdelegate start(key, opts \\ []), to: PoliteClient.ClientsMgr
end
