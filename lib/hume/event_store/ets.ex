defmodule Hume.EventStore.ETS do
  @moduledoc """
  An in-memory event store using ETS.
  This is mainly for testing and prototyping purposes.
  It does not support persistence or clustering.
  """

  @behaviour Hume.EventStore

  alias Hume.EventOrder

  def start_link(_) do
    :ets.new(__MODULE__, [:named_table, :ordered_set, :public])
    :ets.insert(__MODULE__, {:seq, 0})
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

  @impl true
  def next_sequence do
    :ets.update_counter(__MODULE__, :seq, {2, 1}, {:seq, 0})
  end

  @impl true
  def events(stream, from) do
    # :ets.fun2ms(fn {{srm, seq}, event} when seq >= from and srm == stream -> event end)
    pattern = [
      {{{:"$1", :"$2"}, :"$3"}, [{:andalso, {:>, :"$2", from}, {:==, :"$1", stream}}], [:"$3"]}
    ]

    :ets.select(__MODULE__, pattern)
    |> EventOrder.ensure_ordered()
  end

  @impl true
  def append_batch(stream, list) do
    list
    |> EventOrder.to_list()
    |> Enum.each(fn {seq, _payload} = event ->
      :ets.insert(__MODULE__, {{stream, seq}, event})
    end)
  end
end
