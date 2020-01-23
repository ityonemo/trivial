defmodule TrivialTest do
  use ExUnit.Case, async: true

  @localhost {127, 0, 0, 1}

  @moduletag :trivial

  alias Trivial.Daemon

  describe "with default settings" do
    test "we can connect to our trivial server and get back trivial data" do
      {:ok, srv} = Daemon.start_link(TrivialStub, "test_file", port: 0)

      # get back the port
      port = Daemon.port(srv)

      {:ok, content} = :tftp.read_file("test_file", :binary, host: @localhost, port: port)

      assert content == "test_file"
    end

    test "we can get data at the chunk size limit" do
      random_content = Enum.map(1..512, fn _ -> Enum.random(?A..?Z) end) |> List.to_string

      {:ok, srv} = Daemon.start_link(TrivialStub, random_content, port: 0)

      port = Daemon.port(srv)

      {:ok, content} = :tftp.read_file("test_file", :binary, host: @localhost, port: port)

      assert content == random_content
    end

    test "we can get data just past the chunk size limit" do
      random_content = Enum.map(1..513, fn _ -> Enum.random(?A..?Z) end) |> List.to_string

      {:ok, srv} = Daemon.start_link(TrivialStub, random_content, port: 0)

      port = Daemon.port(srv)

      {:ok, content} = :tftp.read_file("test_file", :binary, host: @localhost, port: port)

      assert content == random_content
    end

    test "we can get data from multiple chunks" do

      total_data = 512 * 8
      random_content = Enum.map(1..total_data, fn _ -> Enum.random(?A..?Z) end) |> List.to_string

      {:ok, srv} = Daemon.start_link(TrivialStub, random_content, port: 0)

      port = Daemon.port(srv)

      {:ok, content} = :tftp.read_file("test_file", :binary, host: @localhost, port: port)

      assert content == random_content

    end
  end

  describe "with a blocksize setting" do
    test "we can connect to our trivial server and get back trivial data" do
      {:ok, srv} = Daemon.start_link(TrivialStub, "test_file", port: 0)

      # get back the port
      port = Daemon.port(srv)

      {:ok, content} = :tftp.read_file("test_file", :binary, [{'blksize', '1428'}] ++ [host: @localhost, port: port])

      assert content == "test_file"
    end

    test "we can get chunk size limit data" do

      random_content = Enum.map(1..1428, fn _ -> Enum.random(?A..?Z) end) |> List.to_string

      {:ok, srv} = Daemon.start_link(TrivialStub, random_content, port: 0)

      # get back the port
      port = Daemon.port(srv)

      {:ok, content} = :tftp.read_file(
        "test_file",
        :binary,
        [{'blksize', '1428'}] ++
        [host: @localhost, port: port])

      assert content == random_content
    end
  end

  describe "with tsize setting" do
    test "we can connect to our trivial server and get back trivial data" do
      {:ok, srv} = Daemon.start_link(TrivialStub, "test_file", port: 0)

      # get back the port
      port = Daemon.port(srv)

      {:ok, content} = :tftp.read_file(
        "test_file",
        :binary,
        [{'blksize', '1428'}] ++
        [host: @localhost, port: port, use_tsize: true])

      assert content == "test_file"
    end
  end
end
