defmodule Hume.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Hume.Bus},
      Hume.Heir,
      Hume.Projection.ETSOwner,
      {Task.Supervisor, name: Hume.TaskSupervisor},
      Hume.QueueSupervisor
    ]

    opts = [strategy: :one_for_one, name: Hume.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
