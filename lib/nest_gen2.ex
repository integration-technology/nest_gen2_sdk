defmodule NestGen2 do
  @moduledoc """
  SDK for a rooted Nest Learning Thermostat (2nd gen).

  Adding `:nest_gen2` as a dependency starts the SDK: the backplate link and
  keep-alive, display, dial, piezo, backlight and power management.

  Subscribe to events with `subscribe/1`; each arrives as
  `{:nest_gen2, topic, payload}`:

  | Topic | Payload |
  |---|---|
  | `:dial` | `%{delta: degrees, angle: degrees}` |
  | `:dial_step` | `%{direction: :cw \\| :ccw, angle: degrees}` |
  | `:light` | `%{level: counts}` (light flickering as someone moves nearby, or switched on) |
  | `:button` | `:down \\| :up` |
  | `:motion` | `%{level: 0..10, near: boolean, far: boolean}` |
  | `:climate` | `%{temperature_c: float, humidity_pct: float}` |
  | `:battery` | `%{millivolts: integer}` |
  | `:power` | `:awake \\| :asleep` |
  """

  @registry NestGen2.Registry
  @topics [:dial, :dial_step, :button, :motion, :light, :climate, :battery, :power]

  @type topic :: :dial | :dial_step | :button | :motion | :climate | :battery | :power

  @doc "Subscribes the calling process to one topic or a list of topics."
  @spec subscribe(topic | [topic]) :: :ok
  def subscribe(topics) when is_list(topics), do: Enum.each(topics, &subscribe/1)

  def subscribe(topic) when topic in @topics do
    unless topic in Registry.keys(@registry, self()) do
      {:ok, _} = Registry.register(@registry, topic, nil)
    end

    :ok
  end

  @doc "Unsubscribes the calling process from one topic or a list of topics."
  @spec unsubscribe(topic | [topic]) :: :ok
  def unsubscribe(topics) when is_list(topics), do: Enum.each(topics, &unsubscribe/1)
  def unsubscribe(topic) when topic in @topics, do: Registry.unregister(@registry, topic)

  @doc false
  def publish(topic, payload) do
    Registry.dispatch(@registry, topic, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:nest_gen2, topic, payload})
    end)
  end
end
