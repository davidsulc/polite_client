defmodule PoliteClient do
  @moduledoc """
  Documentation for PoliteClient.
  """
  defdelegate start(key, opts \\ []), to: PoliteClient.ClientsMgr
end
