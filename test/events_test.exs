defmodule NestGen2.EventsTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!({Registry, keys: :duplicate, name: NestGen2.Registry})
    :ok
  end

  test "subscribers receive published events" do
    :ok = NestGen2.subscribe(:climate)
    NestGen2.publish(:climate, %{temperature_c: 21.5, humidity_pct: 45.0})
    assert_receive {:nest_gen2, :climate, %{temperature_c: 21.5}}
  end

  test "subscribing twice does not duplicate events" do
    :ok = NestGen2.subscribe([:power, :power])
    NestGen2.publish(:power, :awake)
    assert_receive {:nest_gen2, :power, :awake}
    refute_receive {:nest_gen2, :power, :awake}, 50
  end

  test "only subscribed topics arrive" do
    :ok = NestGen2.subscribe(:dial)
    NestGen2.publish(:motion, %{level: 5, near: false, far: true})
    refute_receive {:nest_gen2, :motion, _}, 50
  end

  test "unsubscribe stops events" do
    :ok = NestGen2.subscribe(:battery)
    :ok = NestGen2.unsubscribe(:battery)
    NestGen2.publish(:battery, %{millivolts: 3900})
    refute_receive {:nest_gen2, :battery, _}, 50
  end

  test "unknown topics are rejected" do
    assert_raise FunctionClauseError, fn -> NestGen2.subscribe(:weather) end
  end
end
