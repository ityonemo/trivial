defmodule TrivialTest.ConnSnapshotTest do
  use ExUnit.Case, async: true

  alias Trivial.Conn

  @erlang_tftp_1 {
    :udp,
    :port,
    {127, 0, 0, 1},
    38_700,
    <<0, 1, 116, 101, 115, 116, 95, 102, 105, 108, 101, 0,
      111, 99, 116, 101, 116, 0>>}

  describe "when sent a connection request from erlang/tftp" do
    test "the connection request is translated" do
      assert {:ok, %Conn{
        mode: :read,
        filename: "test_file",
        client_ip: {127, 0, 0, 1},
        client_port: 38_700,
      }} = Conn.from_request(@erlang_tftp_1, {nil, nil})
    end
  end
end
