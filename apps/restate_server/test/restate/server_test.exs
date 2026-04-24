defmodule Restate.ServerTest do
  use ExUnit.Case
  doctest Restate.Server

  test "greets the world" do
    assert Restate.Server.hello() == :world
  end
end
