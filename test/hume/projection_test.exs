defmodule Hume.ProjectionTest do
  use ExUnit.Case, async: true

  alias Hume.Projection

  describe "parse_options/1" do
    test "parses valid options correctly" do
      opts = [
        projection: :my_projection,
        stream: [:stream1, :stream2],
        extra: :value
      ]

      assert {:ok,
              {%{projection: :my_projection, streams: [:stream1, :stream2]}, [extra: :value]}} =
               Projection.parse_options(opts)
    end

    test "returns error for missing required options" do
      opts = [projection: :my_projection]
      assert {:error, :missing_stream} = Projection.parse_options(opts)
    end

    test "handles empty options list" do
      assert {:error, :missing_stream} = Projection.parse_options([])
    end
  end

  describe "validate/1" do
    defmodule ValidProjection do
      @moduledoc false
      @behaviour Hume.Projection
      def init_state(_opts), do: {:ok, %{}}
      def handle_event(_event, _state), do: {:ok, %{}}
      def last_snapshot(_projection), do: %{}
      def persist_snapshot(_projection, _state), do: :ok
    end

    defmodule InvalidProjection do
      @moduledoc false
      def some_function(), do: :ok
    end

    test "validates a correct projection module" do
      assert :ok = Projection.validate(ValidProjection)
    end

    test "returns error for invalid projection module" do
      assert {:error, :invalid_module} = Projection.validate(InvalidProjection)
    end
  end
end
