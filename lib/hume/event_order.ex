defmodule Hume.EventOrder do
  @moduledoc """
  Provides utilities for working with ordered event sequences.

  Events are tuples of `{sequence_number, event_data}` where sequence numbers
  are integers used to maintain ordering. This module provides functions to
  check ordering, ensure ordering, and merge ordered event sequences.
  """

  @type event :: {integer(), term()}
  @opaque ordered :: {:ordered, [event()]}

  @doc """
  Checks if a list of events is ordered by sequence number.

  ## Examples

      iex> Hume.EventOrder.ordered?([])
      true

      iex> Hume.EventOrder.ordered?([{1, :foo}])
      true

      iex> Hume.EventOrder.ordered?([{1, :foo}, {2, :bar}, {3, :baz}])
      true

      iex> Hume.EventOrder.ordered?([{1, :foo}, {3, :bar}, {2, :baz}])
      false

      iex> Hume.EventOrder.ordered?([{2, :foo}, {1, :bar}])
      false
  """
  @spec ordered?([event()] | ordered()) :: boolean()
  def ordered?([]), do: true
  def ordered?([_]), do: true
  def ordered?({:ordered, _}), do: true

  def ordered?([{s1, _} = _e1, {s2, _} = _e2 | rest]) when s1 < s2,
    do: ordered?([{s2, nil} | rest] |> normalize_pair())

  def ordered?(_), do: false

  # Internal: normalize event pairs for next comparison (keep only {seq, _})
  defp normalize_pair([{seq, _} | tail]),
    do: [{seq, nil} | Enum.map(tail, fn {s, _} -> {s, nil} end)]

  @doc """
  Ensures a list of events is ordered, sorting if necessary.

  Returns an `{:ordered, events}` tuple. If the input is already ordered,
  it returns the events as-is. Otherwise, it sorts them by sequence number.

  ## Examples

      iex> Hume.EventOrder.ensure_ordered([{1, :foo}, {2, :bar}])
      {:ordered, [{1, :foo}, {2, :bar}]}

      iex> Hume.EventOrder.ensure_ordered([{2, :bar}, {1, :foo}])
      {:ordered, [{1, :foo}, {2, :bar}]}

      iex> Hume.EventOrder.ensure_ordered([])
      {:ordered, []}
  """
  @spec ensure_ordered([event()]) :: ordered()
  def ensure_ordered(events) do
    if ordered?(events),
      do: {:ordered, events},
      else: {:ordered, Enum.sort_by(events, &elem(&1, 0))}
  end

  @doc """
  Merges two ordered event sequences into a single ordered sequence.

  When events have the same sequence number (conflict), the "later wins"
  policy is applied - the event from the second list takes precedence.

  ## Examples

      iex> Hume.EventOrder.merge_ordered({:ordered, [{1, :a}]}, {:ordered, [{2, :b}]})
      {:ordered, [{1, :a}, {2, :b}]}

      iex> Hume.EventOrder.merge_ordered({:ordered, [{1, :a}, {3, :c}]}, {:ordered, [{2, :b}]})
      {:ordered, [{1, :a}, {2, :b}, {3, :c}]}

      iex> Hume.EventOrder.merge_ordered({:ordered, [{1, :old}]}, {:ordered, [{1, :new}]})
      {:ordered, [{1, :new}]}

      iex> Hume.EventOrder.merge_ordered({:ordered, []}, {:ordered, [{1, :a}]})
      {:ordered, [{1, :a}]}
  """
  @spec merge_ordered(ordered(), ordered()) :: ordered()
  def merge_ordered({:ordered, a}, {:ordered, b}) do
    {:ordered, do_merge(a, b)}
  end

  defp do_merge([], b), do: b
  defp do_merge(a, []), do: a

  defp do_merge([{sa, _va} = ea | ra], [{sb, _vb} = eb | rb]) do
    cond do
      sa < sb -> [ea | do_merge(ra, [eb | rb])]
      sa > sb -> [eb | do_merge([ea | ra], rb)]
      # Conflict policy: "later wins" - event from second list takes precedence
      true -> [eb | do_merge(ra, rb)]
    end
  end

  @doc """
  Returns the length of the event list.

  Works with both raw event lists and `{:ordered, events}` tuples.
  ## Examples

      iex> Hume.EventOrder.len([])
      0

      iex> Hume.EventOrder.len([{1, :foo}, {2, :bar}])
      2

      iex> Hume.EventOrder.len({:ordered, [{1, :foo}, {2, :bar}]})
      2
  """
  @spec len(ordered() | [event()]) :: non_neg_integer()
  def len({:ordered, events}), do: length(events)
  def len(events) when is_list(events), do: length(events)
end
