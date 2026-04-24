defmodule Restate.Example.GreeterTest do
  use ExUnit.Case
  doctest Restate.Example.Greeter

  test "greets the world" do
    assert Restate.Example.Greeter.hello() == :world
  end
end
