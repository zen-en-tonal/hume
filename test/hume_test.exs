defmodule HumeTest do
  @moduledoc false

  use ExUnit.Case, async: true

  defmodule MyStateMachine do
    @moduledoc false

    use Hume.Machine, :use_ets

    def init_state(_), do: %{}

    def handle_event({:add, key, value}, state),
      do: {:ok, Map.put(state || %{}, key, value)}

    def handle_event({:remove, key}, state),
      do: {:ok, Map.delete(state || %{}, key)}

    def next_sequence(_name),
      do: System.unique_integer([:monotonic, :positive])
  end

  doctest Hume

  test "start_link/2 and send_event/2" do
    {:ok, pid} = Hume.start_link(MyStateMachine, use_heir: false, name: :test_machine)

    assert {:ok, {seq1, %{}}} = Hume.send_event(pid, {:add, :foo, 42})
    assert {:ok, {seq2, %{foo: 42}}} = Hume.send_event(pid, {:add, :bar, 100})
    assert {:ok, {seq3, %{bar: 100}}} = Hume.send_event(pid, {:remove, :foo})

    assert seq1 < seq2
    assert seq2 < seq3
  end

  test "snapshot/1 and state/1" do
    {:ok, pid} = Hume.start(MyStateMachine, use_heir: false, name: :test_machine_snapshot)

    assert {:ok, {_seq1, %{}}} = Hume.send_event(pid, {:add, :foo, 42})
    assert {:ok, {_seq2, %{foo: 42}}} = Hume.send_event(pid, {:add, :bar, 100})

    assert {_, %{foo: 42, bar: 100}} = Hume.snapshot(pid)
    assert %{foo: 42, bar: 100} = Hume.state(pid)
  end

  test "start/2 and ETS table ownership transfer" do
    unique_name =
      System.unique_integer([:positive, :monotonic])
      |> Integer.to_string()
      |> String.to_atom()

    {:ok, pid} = Hume.start(MyStateMachine, use_heir: true, name: unique_name)

    assert {:ok, {_seq1, %{}}} = Hume.send_event(pid, {:add, :foo, 42})
    assert {:ok, {_seq2, %{foo: 42}}} = Hume.send_event(pid, {:add, :bar, 100})

    assert {_, %{foo: 42, bar: 100}} = Hume.snapshot(pid)
    assert %{foo: 42, bar: 100} = Hume.state(pid)

    # Simulate process crash
    Process.exit(pid, :kill)
    # Allow some time for the process to restart
    :timer.sleep(100)

    # Restart the machine
    {:ok, pid2} = Hume.start(MyStateMachine, use_heir: true, name: unique_name)

    # Verify state is preserved after restart
    assert %{foo: 42, bar: 100} = Hume.state(pid2)
  end

  test "start/2 without heir process" do
    unique_name =
      System.unique_integer([:positive, :monotonic])
      |> Integer.to_string()
      |> String.to_atom()

    {:ok, pid} = Hume.start(MyStateMachine, use_heir: false, name: unique_name)

    assert {:ok, {_seq1, %{}}} = Hume.send_event(pid, {:add, :foo, 42})
    assert {:ok, {_seq2, %{foo: 42}}} = Hume.send_event(pid, {:add, :bar, 100})

    assert {_, %{foo: 42, bar: 100}} = Hume.snapshot(pid)
    assert %{foo: 42, bar: 100} = Hume.state(pid)

    # Simulate process crash
    Process.exit(pid, :kill)
    # Allow some time for the process to terminate
    :timer.sleep(100)

    # Restart the machine
    {:ok, pid2} = Hume.start(MyStateMachine, use_heir: false, name: unique_name)

    # Verify state is reset after restart
    assert %{} = Hume.state(pid2)
  end

  test "start_link/2 with existing name" do
    {:ok, _pid1} = Hume.start_link(MyStateMachine, use_heir: false, name: :duplicate_name_test)

    assert {:error, {:already_started, _pid2}} =
             Hume.start_link(MyStateMachine, use_heir: false, name: :duplicate_name_test)
  end

  test "start/2 with existing name" do
    {:ok, _pid1} = Hume.start(MyStateMachine, use_heir: false, name: :duplicate_name_test_start)

    assert {:error, {:already_started, _pid2}} =
             Hume.start(MyStateMachine, use_heir: false, name: :duplicate_name_test_start)
  end

  test "replay/2 functionality" do
    init_snapshot = {0, %{}}

    events =
      [{1, {:add, :foo, 42}}, {2, {:add, :bar, 100}}, {3, {:remove, :foo}}]
      |> Hume.EventOrder.ensure_ordered()

    {:ok, final_snapshot} = Hume.replay(MyStateMachine, init_snapshot, events)
    assert final_snapshot == {3, %{bar: 100}}
  end

  test "replay/2 with invalid event" do
    init_snapshot = {0, %{}}

    events =
      [{1, {:add, :foo, 42}}, {2, {:unknown, :event}}, {3, {:remove, :foo}}]
      |> Hume.EventOrder.ensure_ordered()

    assert_raise FunctionClauseError, fn ->
      Hume.replay(MyStateMachine, init_snapshot, events)
    end
  end

  test "replay/2 with partial events" do
    init_snapshot = {0, %{}}

    events1 =
      [{1, {:add, :foo, 42}}, {2, {:add, :bar, 100}}]
      |> Hume.EventOrder.ensure_ordered()

    events2 =
      [{3, {:remove, :foo}}, {4, {:add, :baz, 7}}]
      |> Hume.EventOrder.ensure_ordered()

    {:ok, snapshot_after_first} = Hume.replay(MyStateMachine, init_snapshot, events1)
    {:ok, final_snapshot} = Hume.replay(MyStateMachine, snapshot_after_first, events2)

    assert final_snapshot == {4, %{bar: 100, baz: 7}}
  end

  test "replay/2 with empty events" do
    init_snapshot = {0, %{foo: 42}}

    events =
      []
      |> Hume.EventOrder.ensure_ordered()

    {:ok, final_snapshot} = Hume.replay(MyStateMachine, init_snapshot, events)
    assert final_snapshot == init_snapshot
  end

  test "replay/2 with stale event" do
    init_snapshot = {2, %{foo: 42}}

    events =
      [{1, {:add, :bar, 100}}, {2, {:remove, :foo}}]
      |> Hume.EventOrder.ensure_ordered()

    assert {:error, _reason} = Hume.replay(MyStateMachine, init_snapshot, events)
  end

  test "replay/2 prevents the raw list" do
    init_snapshot = {0, %{}}

    events = [{1, {:add, :foo, 42}}, {2, {:add, :bar, 100}}]

    assert_raise FunctionClauseError, fn ->
      Hume.replay(MyStateMachine, init_snapshot, events)
    end
  end

  test "snapshot/1 on uninitialized machine" do
    {:ok, pid} = Hume.start(MyStateMachine, use_heir: false, name: :uninitialized_snapshot)

    assert {0, %{}} = Hume.snapshot(pid)
  end

  test "state/1 on uninitialized machine" do
    {:ok, pid} = Hume.start(MyStateMachine, use_heir: false, name: :uninitialized_state)

    assert %{} = Hume.state(pid)
  end
end
