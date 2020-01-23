defmodule TrivialTest do
  use ExUnit.Case
  doctest Trivial

  test "greets the world" do
    assert Trivial.hello() == :world
  end
end
