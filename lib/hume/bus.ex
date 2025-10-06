defmodule Hume.Bus do
  @moduledoc false

  def notify(store, stream, last_seq),
    do: Phoenix.PubSub.broadcast(__MODULE__, topic(store, stream), {:hint, stream, last_seq})

  def subscribe(store, stream),
    do: Phoenix.PubSub.subscribe(__MODULE__, topic(store, stream))

  defp topic(store, stream),
    do: {store, stream} |> :erlang.phash2() |> Integer.to_string()
end
