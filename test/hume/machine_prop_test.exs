defmodule Hume.Machine.PropTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use ExUnitProperties

  defmodule MyStateMachine do
    @moduledoc false

    use Hume.Machine, :use_ets

    def init_state(_), do: %{}

    def handle_event({:add, key, value}, state),
      do: {:ok, Map.put(state || %{}, key, value)}

    def handle_event({:remove, key}, state),
      do: {:ok, Map.delete(state || %{}, key)}

    def next_sequence(_name),
      do: System.unique_integer([:monotonic, :positive])
  end

  defp key_gen do
    member_of([:a, :b, :c, :d, :e])
  end

  defp val_gen do
    integer(-100..100)
  end

  defp event_gen do
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

  property "Hume Machine should be same state with simple KVS" do
    check all(events <- list_of(event_gen(), min_length: 0, max_length: 200)) do
      {:ok, pid} = Hume.start_link(MyStateMachine, use_heir: false, name: unique_name())

      expected =
        Enum.reduce(events, %{}, fn e, m -> kvs_apply(m, e) end)

      machine_state =
        Enum.reduce(events, %{}, fn e, _acc ->
          assert {:ok, {_seq, s}} = Hume.send_event(pid, e)
          s
        end)

      final_state = if events == [], do: %{}, else: machine_state

      assert final_state == expected
    end
  end

  property "イベントの分割適用でも結果は同じ（結合性テスト）" do
    check all(
            left <- list_of(event_gen(), max_length: 50),
            right <- list_of(event_gen(), max_length: 50)
          ) do
      {:ok, pid} = Hume.start_link(MyStateMachine, use_heir: false, name: unique_name())

      left_state =
        Enum.reduce(left, %{}, fn e, _acc ->
          assert {:ok, {_seq, s}} = Hume.send_event(pid, e)
          s
        end)

      right_state =
        Enum.reduce(right, %{}, fn e, _acc ->
          assert {:ok, {_seq, s}} = Hume.send_event(pid, e)
          s
        end)

      final_machine =
        case {left, right} do
          {[], []} -> %{}
          {[], _} -> right_state
          {_, []} -> left_state
          _ -> right_state
        end

      expected =
        (left ++ right)
        |> Enum.reduce(%{}, fn e, m -> kvs_apply(m, e) end)

      assert final_machine == expected
    end
  end

  property "recovery test" do
    check all(
            first <- list_of(event_gen(), max_length: 100),
            then <- list_of(event_gen(), max_length: 100)
          ) do
      unique_name = unique_name()

      {:ok, pid} = Hume.start(MyStateMachine, use_heir: true, name: unique_name)

      first_state =
        Enum.reduce(first, %{}, fn e, _acc ->
          assert {:ok, {_seq, s}} = Hume.send_event(pid, e)
          s
        end)

      Process.exit(pid, :kill)
      :timer.sleep(100)
      {:ok, pid} = Hume.start(MyStateMachine, use_heir: true, name: unique_name)

      then_state =
        Enum.reduce(then, %{}, fn e, _acc ->
          assert {:ok, {_seq, s}} = Hume.send_event(pid, e)
          s
        end)

      final_machine =
        case {first, then} do
          {[], []} -> %{}
          {[], _} -> then_state
          {_, []} -> first_state
          _ -> then_state
        end

      expected =
        (first ++ then)
        |> Enum.reduce(%{}, fn e, m -> kvs_apply(m, e) end)

      assert final_machine == expected
    end
  end
end
