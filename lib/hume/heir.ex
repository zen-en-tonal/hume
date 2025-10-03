defmodule Hume.Heir do
  @moduledoc false

  use GenServer

  def start_link(_opts \\ []),
    do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(s), do: {:ok, s}

  @impl true
  def handle_info({:"ETS-TRANSFER", tid, _from, name}, s) do
    :telemetry.execute([:hume_heir, :transfer, :received], %{}, %{name: name, tid: tid})
    {:noreply, Map.put(s, name, tid)}
  end

  def request_take(name, new_owner) do
    GenServer.call(__MODULE__, {:take, name, new_owner})
  end

  @impl true
  def handle_call({:take, name, new_owner}, _from, s) do
    case Map.pop(s, name) do
      {nil, _} ->
        :telemetry.execute([:hume_heir, :transfer, :not_found], %{}, %{name: name})
        {:reply, {:error, :not_found}, s}

      {tid, s2} ->
        true = :ets.give_away(tid, new_owner, :ok)
        # :telemetry.execute([:hume_heir, :transfer, :sent], %{}, %{name: name, tid: tid})
        {:reply, {:ok, tid}, s2}
    end
  end
end
