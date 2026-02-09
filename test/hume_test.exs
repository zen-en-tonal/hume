defmodule HumeTest do
  @moduledoc false

  use ExUnit.Case, async: false

  defmodule MyProjection do
    @moduledoc false

    use Hume.Projection, use_ets: true, store: Hume.EventStore.ETS

    @impl true
    def init_state(_), do: %{}

    @impl true
    def handle_event({:add, key, value}, state),
      do: {:ok, Map.put(state || %{}, key, value)}

    @impl true
    def handle_event({:remove, key}, state),
      do: {:ok, Map.delete(state || %{}, key)}
  end

  defmodule MyStream do
    @moduledoc false
    @behaviour Hume.EventStore

    @impl true
    def events(_stream, _from) do
      Stream.resource(
        fn -> 1 end,
        fn
          state when state > 10 -> {:halt, state}
          state -> {[{state, {:add, state, state}}], state + 1}
        end,
        fn _ -> :ok end
      )
    end

    @impl true
    def append_batch(_stream, _list), do: :ok
  end

  defmodule MyStreamProjection do
    @moduledoc false
    use Hume.Projection, use_ets: true, store: MyStream
    @impl true
    def init_state(_), do: %{}
    @impl true
    def handle_event({:add, key, value}, state),
      do: {:ok, Map.put(state || %{}, key, value)}
  end

  doctest Hume

  describe "start_link/2" do
    setup do
      {:ok, _} = Hume.EventStore.ETS.start_link([])
      :ok
    end

    test "starts the projection process" do
      assert {:ok, pid} =
               Hume.start_link(MyProjection, stream: unique_name(), projection: unique_name())

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "starts the projection process with use_heir option" do
      assert {:ok, pid} =
               Hume.start_link(MyProjection,
                 stream: unique_name(),
                 use_heir: true,
                 projection: unique_name()
               )

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "fails to start with invalid module" do
      assert {:error, _} =
               Hume.start_link(:invalid_module, stream: unique_name(), projection: unique_name())
    end

    test "singleton projection name on local" do
      name = unique_name()

      assert {:ok, pid1} =
               Hume.start_link(MyProjection,
                 stream: unique_name(),
                 name: name
               )

      assert {:error, {:already_started, ^pid1}} =
               Hume.start_link(MyProjection,
                 stream: unique_name(),
                 name: name
               )
    end

    test "singleton projection name on global" do
      name = unique_name()

      assert {:ok, pid1} =
               Hume.start_link(MyProjection,
                 stream: unique_name(),
                 name: {:global, name}
               )

      assert {:error, {:already_started, ^pid1}} =
               Hume.start_link(MyProjection,
                 stream: unique_name(),
                 name: {:global, name}
               )

      assert ^pid1 = :global.whereis_name(name)
    end

    test "singleton projection name on via" do
      name = unique_name()
      registry = unique_name()

      {:ok, _} = Registry.start_link(keys: :unique, name: registry)

      assert {:ok, pid1} =
               Hume.start_link(MyProjection,
                 stream: unique_name(),
                 name: {:via, Registry, {registry, name}}
               )

      assert {:error, {:already_started, ^pid1}} =
               Hume.start_link(MyProjection,
                 stream: unique_name(),
                 name: {:via, Registry, {registry, name}}
               )

      assert [{^pid1, _}] = Registry.lookup(registry, name)
    end
  end

  describe "start/2" do
    setup do
      {:ok, _} = Hume.EventStore.ETS.start_link([])
      :ok
    end

    test "starts the projection process without linking" do
      assert {:ok, pid} =
               Hume.start(MyProjection, stream: unique_name(), projection: unique_name())

      assert is_pid(pid)
      assert Process.alive?(pid)
      # Ensure the process is not linked to the current process
      refute Enum.any?(Process.info(self(), :links) |> elem(1), fn link -> link == pid end)
    end

    test "starts the projection process with use_heir option without linking" do
      assert {:ok, pid} =
               Hume.start(MyProjection,
                 stream: unique_name(),
                 use_heir: true,
                 projection: unique_name()
               )

      assert is_pid(pid)
      assert Process.alive?(pid)
      # Ensure the process is not linked to the current process
      refute Enum.any?(Process.info(self(), :links) |> elem(1), fn link -> link == pid end)
    end

    test "accepts stream event store" do
      assert {:ok, pid} =
               Hume.start(MyStreamProjection,
                 stream: unique_name(),
                 projection: unique_name()
               )

      assert is_pid(pid)
      assert Process.alive?(pid)

      assert Hume.Projection.state(pid) == %{
               1 => 1,
               2 => 2,
               3 => 3,
               4 => 4,
               5 => 5,
               6 => 6,
               7 => 7,
               8 => 8,
               9 => 9,
               10 => 10
             }
    end

    test "fails to start without linking with invalid module" do
      assert {:error, _} =
               Hume.start(:invalid_module, stream: unique_name(), projection: unique_name())
    end
  end

  describe "publish/3" do
    setup do
      {:ok, _} = Hume.EventStore.ETS.start_link([])
      :ok
    end

    test "publishes a single event and updates the state" do
      name = unique_name()

      {:ok, pid} =
        Hume.start_link(MyProjection,
          stream: name,
          use_heir: false,
          projection: name
        )

      assert {:ok, _} = Hume.publish(Hume.EventStore.ETS, name, {:add, :foo, 42})
      # Allow some time for the event to be processed
      Process.sleep(100)
      assert Hume.Projection.state(pid) == %{foo: 42}
    end

    test "publishes multiple events and updates the state" do
      name = unique_name()

      {:ok, pid} =
        Hume.start_link(MyProjection,
          stream: name,
          use_heir: false,
          projection: name
        )

      assert {:ok, _} =
               Hume.publish(Hume.EventStore.ETS, name, [{:add, :foo, 42}, {:add, :bar, 84}])

      # Allow some time for the events to be processed
      Process.sleep(100)
      assert Hume.Projection.state(pid) == %{foo: 42, bar: 84}
    end

    test "publishes an event to remove a key and updates the state" do
      name = unique_name()

      {:ok, pid} =
        Hume.start_link(MyProjection,
          stream: name,
          use_heir: false,
          projection: name
        )

      assert {:ok, _} = Hume.publish(Hume.EventStore.ETS, name, {:add, :foo, 42})
      Process.sleep(100)
      assert {:ok, _} = Hume.publish(Hume.EventStore.ETS, name, {:remove, :foo})
      Process.sleep(100)
      assert Hume.Projection.state(pid) == %{}
    end

    test "publishes an empty list of events" do
      assert {:ok, []} = Hume.publish(Hume.EventStore.ETS, MyStream, [])
    end
  end

  defp unique_name do
    System.unique_integer()
    |> Integer.to_string()
    |> String.to_atom()
  end
end
