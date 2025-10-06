defmodule Hume.Projection.ETSOwner do
  @moduledoc false
  use GenServer

  @table :hume_projection_snapshots

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    # Create ETS table and set the heir to Hume.Heir
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :public,
        {:heir, Process.whereis(Hume.Heir), @table},
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    {:ok, state}
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", _, _, _}, s) do
    {:noreply, s}
  end

  def table, do: @table
end
