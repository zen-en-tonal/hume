defmodule Hume.EventOrderTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Hume.EventOrder

  doctest Hume.EventOrder

  describe "ordered?/1" do
    test "returns true for empty list" do
      assert EventOrder.ordered?([])
    end

    test "returns true for single event" do
      assert EventOrder.ordered?([{1, :event}])
      assert EventOrder.ordered?([{100, :data}])
    end

    test "returns true for ordered events" do
      assert EventOrder.ordered?([{1, :a}, {2, :b}])
      assert EventOrder.ordered?([{1, :a}, {2, :b}, {3, :c}])
      assert EventOrder.ordered?([{1, :a}, {2, :b}, {3, :c}, {4, :d}])
    end

    test "returns true for ordered events with gaps in sequence" do
      assert EventOrder.ordered?([{1, :a}, {5, :b}, {10, :c}])
      assert EventOrder.ordered?([{0, :a}, {100, :b}, {200, :c}])
    end

    test "returns false for unordered events" do
      refute EventOrder.ordered?([{2, :a}, {1, :b}])
      refute EventOrder.ordered?([{1, :a}, {3, :b}, {2, :c}])
      refute EventOrder.ordered?([{3, :a}, {2, :b}, {1, :c}])
    end

    test "returns false when events have equal sequence numbers" do
      refute EventOrder.ordered?([{1, :a}, {1, :b}])
      refute EventOrder.ordered?([{1, :a}, {2, :b}, {2, :c}])
    end

    test "handles events with negative sequence numbers" do
      assert EventOrder.ordered?([{-5, :a}, {-2, :b}, {0, :c}, {5, :d}])
      refute EventOrder.ordered?([{-2, :a}, {-5, :b}])
    end

    test "handles events with various data types" do
      assert EventOrder.ordered?([{1, "string"}, {2, :atom}, {3, %{key: :value}}, {4, [1, 2, 3]}])
    end
  end

  describe "ensure_ordered/1" do
    test "returns ordered tuple for empty list" do
      assert {:ordered, []} = EventOrder.ensure_ordered([])
    end

    test "returns ordered tuple for single event" do
      assert {:ordered, [{1, :event}]} = EventOrder.ensure_ordered([{1, :event}])
    end

    test "returns ordered tuple for already ordered events" do
      events = [{1, :a}, {2, :b}, {3, :c}]
      assert {:ordered, ^events} = EventOrder.ensure_ordered(events)
    end

    test "sorts unordered events by sequence number" do
      assert {:ordered, [{1, :a}, {2, :b}, {3, :c}]} =
               EventOrder.ensure_ordered([{3, :c}, {1, :a}, {2, :b}])

      assert {:ordered, [{1, :a}, {2, :b}, {3, :c}]} =
               EventOrder.ensure_ordered([{2, :b}, {3, :c}, {1, :a}])
    end

    test "sorts events with gaps in sequence" do
      assert {:ordered, [{1, :a}, {5, :b}, {10, :c}]} =
               EventOrder.ensure_ordered([{10, :c}, {1, :a}, {5, :b}])
    end

    test "handles duplicate sequence numbers" do
      # When duplicates exist, sorting is stable in terms of order
      result = EventOrder.ensure_ordered([{2, :b}, {1, :a}, {2, :c}])
      assert {:ordered, events} = result
      assert length(events) == 3
      [first, second, third] = events
      assert first == {1, :a}
      # Both {2, :b} and {2, :c} should be present, but order may vary
      assert elem(second, 0) == 2
      assert elem(third, 0) == 2
    end

    test "handles negative sequence numbers" do
      assert {:ordered, [{-5, :a}, {-2, :b}, {0, :c}]} =
               EventOrder.ensure_ordered([{0, :c}, {-5, :a}, {-2, :b}])
    end
  end

  describe "merge_ordered/2" do
    test "merges two empty lists" do
      assert {:ordered, []} = EventOrder.merge_ordered({:ordered, []}, {:ordered, []})
    end

    test "merges empty list with non-empty list" do
      assert {:ordered, [{1, :a}, {2, :b}]} =
               EventOrder.merge_ordered({:ordered, []}, {:ordered, [{1, :a}, {2, :b}]})

      assert {:ordered, [{1, :a}, {2, :b}]} =
               EventOrder.merge_ordered({:ordered, [{1, :a}, {2, :b}]}, {:ordered, []})
    end

    test "merges non-overlapping ordered lists" do
      assert {:ordered, [{1, :a}, {2, :b}, {3, :c}, {4, :d}]} =
               EventOrder.merge_ordered(
                 {:ordered, [{1, :a}, {2, :b}]},
                 {:ordered, [{3, :c}, {4, :d}]}
               )

      assert {:ordered, [{1, :a}, {2, :b}, {3, :c}, {4, :d}]} =
               EventOrder.merge_ordered(
                 {:ordered, [{3, :c}, {4, :d}]},
                 {:ordered, [{1, :a}, {2, :b}]}
               )
    end

    test "merges interleaved ordered lists" do
      assert {:ordered, [{1, :a}, {2, :b}, {3, :c}, {4, :d}]} =
               EventOrder.merge_ordered(
                 {:ordered, [{1, :a}, {3, :c}]},
                 {:ordered, [{2, :b}, {4, :d}]}
               )

      assert {:ordered, [{1, :a}, {2, :b}, {3, :c}, {4, :d}, {5, :e}]} =
               EventOrder.merge_ordered(
                 {:ordered, [{1, :a}, {3, :c}, {5, :e}]},
                 {:ordered, [{2, :b}, {4, :d}]}
               )
    end

    test "applies 'later wins' policy for conflicting sequence numbers" do
      # When sequences match, the event from the second list wins
      assert {:ordered, [{1, :new}]} =
               EventOrder.merge_ordered(
                 {:ordered, [{1, :old}]},
                 {:ordered, [{1, :new}]}
               )

      assert {:ordered, [{1, :a}, {2, :new}, {3, :c}]} =
               EventOrder.merge_ordered(
                 {:ordered, [{1, :a}, {2, :old}, {3, :c}]},
                 {:ordered, [{2, :new}]}
               )
    end

    test "handles multiple conflicts" do
      assert {:ordered, [{1, :new1}, {2, :new2}, {3, :c}]} =
               EventOrder.merge_ordered(
                 {:ordered, [{1, :old1}, {2, :old2}, {3, :c}]},
                 {:ordered, [{1, :new1}, {2, :new2}]}
               )
    end

    test "merges lists with gaps" do
      assert {:ordered, [{1, :a}, {5, :b}, {10, :c}, {15, :d}]} =
               EventOrder.merge_ordered(
                 {:ordered, [{1, :a}, {10, :c}]},
                 {:ordered, [{5, :b}, {15, :d}]}
               )
    end

    test "handles negative sequence numbers" do
      assert {:ordered, [{-5, :a}, {-2, :b}, {0, :c}, {3, :d}]} =
               EventOrder.merge_ordered(
                 {:ordered, [{-5, :a}, {0, :c}]},
                 {:ordered, [{-2, :b}, {3, :d}]}
               )
    end

    test "merges single element lists" do
      assert {:ordered, [{1, :a}, {2, :b}]} =
               EventOrder.merge_ordered({:ordered, [{1, :a}]}, {:ordered, [{2, :b}]})

      assert {:ordered, [{1, :b}]} =
               EventOrder.merge_ordered({:ordered, [{1, :a}]}, {:ordered, [{1, :b}]})
    end

    test "maintains order for complex merge scenarios" do
      result =
        EventOrder.merge_ordered(
          {:ordered, [{1, :a}, {3, :c}, {5, :e}, {7, :g}]},
          {:ordered, [{2, :b}, {4, :d}, {6, :f}, {8, :h}]}
        )

      assert {:ordered,
              [
                {1, :a},
                {2, :b},
                {3, :c},
                {4, :d},
                {5, :e},
                {6, :f},
                {7, :g},
                {8, :h}
              ]} = result
    end
  end

  describe "integration tests" do
    test "ensure_ordered and merge_ordered work together" do
      unordered1 = [{3, :c}, {1, :a}]
      unordered2 = [{4, :d}, {2, :b}]

      ordered1 = EventOrder.ensure_ordered(unordered1)
      ordered2 = EventOrder.ensure_ordered(unordered2)

      result = EventOrder.merge_ordered(ordered1, ordered2)

      assert {:ordered, [{1, :a}, {2, :b}, {3, :c}, {4, :d}]} = result
    end

    test "ordered? works with result of ensure_ordered" do
      unordered = [{5, :e}, {1, :a}, {3, :c}]
      {:ordered, events} = EventOrder.ensure_ordered(unordered)

      assert EventOrder.ordered?(events)
    end

    test "ordered? works with result of merge_ordered" do
      {:ordered, merged} =
        EventOrder.merge_ordered(
          {:ordered, [{1, :a}, {3, :c}]},
          {:ordered, [{2, :b}, {4, :d}]}
        )

      assert EventOrder.ordered?(merged)
    end
  end
end
