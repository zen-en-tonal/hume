defmodule Hume.Projection.PropTest do
  @moduledoc false

  use ExUnit.Case, async: false
  use ExUnitProperties

  defmodule SUT do
    @moduledoc false

    use Hume.Projection, use_ets: true, store: Hume.EventStore.ETS

    @impl true
    def init_state(_), do: %{}

    @impl true
    def handle_event({:add, key, value}, state),
      do: {:ok, Map.put(state || %{}, key, value)}

    @impl true
    def handle_event({:remove, key}, state),
      do: {:ok, Map.delete(state || %{}, key)}
  end

  defp key_gen do
    member_of([:a, :b, :c, :d, :e])
  end

  defp val_gen do
    integer(-100..100)
  end

  defp payload_gen do
    one_of([
      map({key_gen(), val_gen()}, fn {k, v} -> {:add, k, v} end),
      map(key_gen(), fn k -> {:remove, k} end)
    ])
  end

  defp kvs_apply(model, {:add, k, v}), do: Map.put(model, k, v)
  defp kvs_apply(model, {:remove, k}), do: Map.delete(model, k)

  defp unique_name do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string()
    |> String.to_atom()
  end

  describe "" do
    property "Hume Projection should be same state with simple KVS" do
      start_supervised(Hume.EventStore.ETS, [])

      check all(payloads <- list_of(payload_gen(), min_length: 0, max_length: 200)) do
        name = unique_name()

        {:ok, pid} =
          Hume.start_link(SUT,
            stream: name,
            projection: unique_name()
          )

        expected =
          Enum.reduce(payloads, %{}, fn e, m -> kvs_apply(m, e) end)

        assert {:ok, _} = Hume.publish(SUT.store(), name, payloads)
        :timer.sleep(10)

        Hume.Projection.catch_up(pid)
        :timer.sleep(10)

        final_state = Hume.Projection.state(pid)

        assert final_state == expected
      end
    end

    property "イベントの分割適用でも結果は同じ（結合性テスト）" do
      start_supervised(Hume.EventStore.ETS, [])

      check all(
              left <- list_of(payload_gen(), max_length: 50),
              right <- list_of(payload_gen(), max_length: 50)
            ) do
        name = unique_name()

        {:ok, pid} =
          Hume.start_link(SUT,
            stream: name,
            projection: unique_name()
          )

        assert {:ok, _} = Hume.publish(SUT.store(), name, left)
        assert {:ok, _} = Hume.publish(SUT.store(), name, right)
        :timer.sleep(10)

        expected =
          (left ++ right)
          |> Enum.reduce(%{}, fn e, m -> kvs_apply(m, e) end)

        Hume.Projection.catch_up(pid)
        :timer.sleep(10)

        final_state = Hume.Projection.state(pid)

        assert final_state == expected
      end
    end

    property "recovery test" do
      start_supervised(Hume.EventStore.ETS, [])

      check all(
              first <- list_of(payload_gen(), max_length: 100),
              then <- list_of(payload_gen(), max_length: 100)
            ) do
        projection = unique_name()
        name = unique_name()

        {:ok, pid} =
          Hume.start(SUT,
            stream: name,
            projection: projection
          )

        assert {:ok, _} = Hume.publish(SUT.store(), name, first)

        Process.exit(pid, :kill)
        :timer.sleep(100)

        {:ok, pid} =
          Hume.start(SUT,
            stream: name,
            projection: projection
          )

        assert {:ok, _} = Hume.publish(SUT.store(), name, then)
        :timer.sleep(10)

        expected =
          (first ++ then)
          |> Enum.reduce(%{}, fn e, m -> kvs_apply(m, e) end)

        Hume.Projection.catch_up(pid)
        :timer.sleep(10)

        final_state = Hume.Projection.state(pid)

        assert final_state == expected
      end
    end
  end
end
