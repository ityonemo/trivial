defmodule TrivialTest.OtpTest do
  use ExUnit.Case, async: true

  alias Trivial.Daemon

  @localhost {127, 0, 0, 1}

  @moduletag :otp

  # put a little bit of time between each test to allow
  # for global name handlers to clear.
  setup do
    Process.sleep(10)
    :ok
  end

  describe "if we start trivial supervised" do
    test "a supervised trivial has a dynamic_supervisor" do
      children = [
        {Trivial, {TrivialStub, "foo", port: 0, name: :sup_test, trivial_name: Foo}}]

      Supervisor.start_link(
        children, strategy: :one_for_one)

      # make sure the sup_test name makes it to the daemon.
      assert Process.whereis(:sup_test)
        == Trivial.daemon(Foo)

      # make sure the server supervisor is known to the daemon.
      assert Daemon.server_supervisor(:sup_test)
        == Trivial.server_supervisor(Foo)
    end

    test "it creates a supervised trivial" do
      children = [
        {Trivial, {TrivialStub, "foo", port: 0, name: :sup_test, trivial_name: Foo}}]

      Supervisor.start_link(children, strategy: :one_for_one)

      tftp_port = Daemon.port(:sup_test)

      assert {:ok, "foo"} == :tftp.read_file(
        "bar",
        :binary,
        host: @localhost, port: tftp_port)
    end

    test "we can kill the daemon and it's okay" do
      children = [
        {Trivial, {TrivialStub, "foo", port: 0, name: :sup_test, trivial_name: Foo}}]

      Supervisor.start_link(children, strategy: :one_for_one)

      Process.sleep(100)

      :sup_test
      |> Process.whereis
      |> Process.exit(:brutal_kill)

      Process.sleep(100)

      tftp_port = Daemon.port(:sup_test)

      assert {:ok, "foo"} == :tftp.read_file(
        "bar",
        :binary,
        host: @localhost, port: tftp_port)
    end

    test "a crashing request is totally okay" do
      children = [
        {Trivial, {TrivialStub, "foo", port: 0, name: :sup_test, trivial_name: Foo}}]

      Supervisor.start_link(children, strategy: :one_for_one)

      tftp_port = Daemon.port(:sup_test)

      assert _ = :tftp.read_file(
        "crash!",  # trigger the crashing route
        :binary,
        host: @localhost, port: tftp_port, max_retries: 1)

      assert {:ok, "foo"} == :tftp.read_file(
        "bar",
        :binary,
        host: @localhost, port: tftp_port)
    end
  end

end
