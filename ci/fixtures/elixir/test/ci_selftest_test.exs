defmodule CiSelftestTest do
  use ExUnit.Case
  doctest CiSelftest

  test "greets the world" do
    assert CiSelftest.hello() == :world
  end
end
