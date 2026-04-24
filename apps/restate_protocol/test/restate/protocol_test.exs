defmodule Restate.ProtocolTest do
  use ExUnit.Case
  doctest Restate.Protocol

  test "greets the world" do
    assert Restate.Protocol.hello() == :world
  end
end
