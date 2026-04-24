defmodule Restate.Protocol.FramerTest do
  use ExUnit.Case, async: true

  alias Dev.Restate.Service.Protocol, as: Pb
  alias Restate.Protocol.{Frame, Framer, Messages}

  describe "header layout" do
    test "EndMessage encodes to type=0x0005, flags=0, length=0" do
      # EndMessage has no fields; protobuf body is empty.
      bytes = Framer.encode(%Pb.EndMessage{})
      assert <<0x0005::16, 0::16, 0::32>> == bytes
      assert byte_size(bytes) == 8
    end

    test "explicit flags propagate into the header" do
      bytes = Framer.encode(%Pb.EndMessage{}, 0xABCD)
      assert <<0x0005::16, 0xABCD::16, 0::32>> == bytes
    end

    test "encode raises for an unregistered module" do
      assert_raise ArgumentError, ~r/no V3 type ID/, fn ->
        Framer.encode(%Pb.StartMessage.StateEntry{key: "k", value: "v"})
      end
    end
  end

  describe "roundtrip" do
    test "StartMessage encode → decode preserves fields" do
      msg = %Pb.StartMessage{
        id: <<1, 2, 3, 4>>,
        debug_id: "inv-debug",
        known_entries: 7
      }

      bytes = Framer.encode(msg)
      assert {:ok, %Frame{type: 0x0000, flags: 0, message: ^msg}, ""} = Framer.decode(bytes)
    end

    test "every message type in the registry roundtrips its empty form" do
      for {type, mod} <- Map.to_list(type_table()) do
        bytes = Framer.encode(struct(mod))

        assert {:ok, %Frame{type: ^type, flags: 0, message: %^mod{}}, ""} =
                 Framer.decode(bytes),
               "roundtrip failed for type=0x#{Integer.to_string(type, 16)} (#{inspect(mod)})"
      end
    end
  end

  describe "decode/1 — partial buffers" do
    test "fewer than 8 bytes returns :more with the original buffer" do
      assert {:more, "abc"} == Framer.decode("abc")
      assert {:more, ""} == Framer.decode("")
    end

    test "header complete but body short returns :more" do
      # Pretend body length is 10 but supply only 3 body bytes.
      buf = <<0x0005::16, 0::16, 10::32, "abc"::binary>>
      assert {:more, ^buf} = Framer.decode(buf)
    end

    test "extra bytes past one frame are returned as rest" do
      one = Framer.encode(%Pb.EndMessage{})
      assert {:ok, %Frame{type: 0x0005}, "tail"} = Framer.decode(one <> "tail")
    end
  end

  describe "decode_all/1" do
    test "drains a stream of frames and returns leftover" do
      msg1 = %Pb.StartMessage{id: <<1>>, known_entries: 0}
      msg2 = %Pb.EndMessage{}
      buf = Framer.encode(msg1) <> Framer.encode(msg2) <> "half"

      assert {:ok, [%Frame{message: ^msg1}, %Frame{message: ^msg2}], "half"} =
               Framer.decode_all(buf)
    end

    test "empty buffer yields no frames and empty leftover" do
      assert {:ok, [], ""} = Framer.decode_all("")
    end
  end

  describe "errors" do
    test "unknown type ID is reported, not crashed on" do
      buf = <<0xFFFE::16, 0::16, 0::32>>
      assert {:error, {:unknown_type, 0xFFFE}} = Framer.decode(buf)
    end
  end

  # Re-derive the table from the public lookup helpers so this test exercises
  # the same surface external callers see.
  defp type_table do
    for type <- 0x0000..0xFFFF, mod = Messages.module_for_type(type), into: %{} do
      {type, mod}
    end
  end
end
