defmodule PoliteClientTest do
  use ExUnit.Case
  doctest PoliteClient

  test "greets the world" do
    assert PoliteClient.hello() == :world
  end
end
