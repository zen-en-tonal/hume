defmodule Hume.EventStore.ETS do
  @moduledoc """
  An in-memory event store using ETS.
  This is mainly for testing and prototyping purposes.
  It does not support persistence or clustering.
  """

  @behaviour Hume.EventStore

  def start_link(_) do
    :ets.new(__MODULE__, [:named_table, :ordered_set, :public])
    {:ok, self()}
  end

  def child_spec(_) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  defp next_sequence(stream) do
    key = {stream, :seq}

    :ets.update_counter(__MODULE__, key, {2, 1}, {key, 0})
  end

  defp current_sequence(stream) do
    case :ets.lookup(__MODULE__, {stream, :seq}) do
      [{{_, :seq}, seq}] -> seq
      _ -> 0
    end
  end

  @impl true
  def events(stream, from) do
    # :ets.fun2ms(fn {{srm, seq}, event} when seq >= from and srm == stream -> event end)
    pattern = [
      {{{:"$1", :"$2"}, :"$3"}, [{:andalso, {:>, :"$2", from}, {:==, :"$1", stream}}], [:"$3"]}
    ]

    :ets.select(__MODULE__, pattern)
    |> Enum.filter(fn
      {_, _} -> true
      _ -> false
    end)
    |> Enum.sort_by(fn {seq, _payload} -> seq end)
  end

  @impl true
  def append(stream, payload, nil) do
    {:ok, insert_event(stream, payload)}
  end

  def append(stream, payload, expect_seq) when is_integer(expect_seq) do
    # Atomically increment the sequence counter and derive the previous value.
    new_seq = :ets.update_counter(__MODULE__, {stream, :seq}, {2, 1}, {{stream, :seq}, 0})
    prev_seq = new_seq - 1

    if prev_seq == expect_seq do
      key = {stream, new_seq}
      value = {new_seq, payload}
      true = :ets.insert(__MODULE__, {key, value})
      {:ok, new_seq}
    else
      {:error, :unexpected_sequence}
    end
  end

  defp insert_event(stream, payload) do
    seq = next_sequence(stream)
    key = {stream, seq}
    value = {seq, payload}
    true = :ets.insert(__MODULE__, {key, value})
    seq
  end
end
