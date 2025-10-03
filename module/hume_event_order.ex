defmodule Hume.EventOrder do
  @type event :: {integer(), term()}
  @type ordered :: {:ordered, [event()]}

  @spec ordered?([event()]) :: boolean()
  def ordered?([]), do: true
  def ordered?([_]), do: true
  def ordered?([{s1, _} = _e1, {s2, _} = _e2 | rest]) when s1 < s2,
    do: ordered?([{s2, nil} | rest] |> normalize_pair())
  def ordered?(_), do: false

  # 内部：次の比較用に {seq, _} だけ残す
  defp normalize_pair([{seq, _} | tail]), do: [{seq, nil} | Enum.map(tail, fn {s, _} -> {s, nil} end)]

  @spec ensure_ordered([event()]) :: ordered()
  def ensure_ordered(events) do
    if ordered?(events), do: {:ordered, events}, else: {:ordered, Enum.sort_by(events, &elem(&1, 0))}
  end

  @spec merge_ordered(ordered(), ordered()) :: ordered()
  def merge_ordered({:ordered, a}, {:ordered, b}) do
    {:ordered, do_merge(a, b)}
  end

  defp do_merge([], b), do: b
  defp do_merge(a, []), do: a
  defp do_merge([{sa, va} = ea | ra], [{sb, vb} = eb | rb]) do
    cond do
      sa < sb -> [ea | do_merge(ra, [eb | rb])]
      sa > sb -> [eb | do_merge([ea | ra], rb)]
      true ->
        # 衝突ポリシー：ここは“後勝ち”例。必要に応じて切り替え
        [eb | do_merge(ra, rb)]
    end
  end
end
