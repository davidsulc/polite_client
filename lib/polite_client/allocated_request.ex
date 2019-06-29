defmodule PoliteClient.AllocatedRequest do
  @enforce_keys [:ref, :owner]
  defstruct ref: nil, owner: nil
end
