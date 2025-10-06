defmodule Hume.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Hume.Bus},
      Hume.Heir,
      Hume.Projection.ETSOwner
    ]

    opts = [strategy: :one_for_one, name: Hume.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
