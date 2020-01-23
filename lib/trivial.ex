defmodule Trivial do

  @moduledoc """

  # A Read-only TFTP Service for Elixir

  ## Motivation

  Erlang's `:tftp` module is quite complex in order to service a broad featureset
  and has some critical bugs which prevent it from being used in a
  [PXE Boot](https://en.wikipedia.org/wiki/Preboot_Execution_Environment) context.

  This library addresses some of these limitations and gives you a way to instrument
  TFTP read requests in a clear and concise fashion.  An emphasis has been made on
  code documentation and commenting, code structuring good practices, with direct
  references to relevant RFC content where appropriate.

  `Trivial` is designed to be a companion to [ExDhcp](https://hexdocs.pm/ex_dhcp/ExDhcp.html)
  to make it easy to build observable and reproducible PXE-Booting solutions.

  ## Security notes

  > TFTP is a fundamentally insecure protocol.  Use of this library for purposes
  > other than its intent (PXE booting) is highly discouraged.  Even when using it
  > for its intended purpose, please be very careful and only use this in networks
  > where you are confident you have visibility and control over OSI layer 2.

  ## Quick Start (Linux)

  1. Write your `MyApplication.Tftp` module with the appropriate
    `Trivial.Server` behaviour callbacks.
      ```
      defmodule MyApplication.Tftp do
        @behaviour Trivial.Server

        @impl true
        def init(request, data) do

        ...
      ```
  2. Set up a trivial server in your application supervisory tree:
      ```
      defmodule MyApplication

        ...

        def start(_type, _args) do

        children = [
          {Trivial, {MyApplication.Tftp, nil, port: 69}}
        ]

        ...

      ```
  3. as superuser, give your beam.smp a the capability to get low ports:
      ```
      setcap 'cap_net_bind_service,cap_net_raw=+ep' /usr/lib/erlang/erts-10.6.1/bin/beam.smp
      ```
      *NB: the path to your beam.smp may be different*

  Note that you may want to use a different strategy to provide access to the
  server, for example, forwarding port 69 to port 6969 via `iptables`.

  ## Supervision Tree

  Trivial generates the following supervision tree:

  - **Supervisor** `:one_for_all`
      - Daemon
      - DynamicSupervisor `:one_for_one`
          - < Servers >

  By default, the top supervisor is named `Trivial`

  ## Without supervision

  See `Trivial.Daemon.start_link/3`

  """

  use Supervisor

  alias Trivial.Daemon

  @typedoc false
  @type t :: {
    server_module :: module,
    server_init :: term,
    opts :: keyword
  }

  @spec start_link(
    server_module :: module,
    server_init :: term,
    opts :: keyword
  ) :: Supervisor.on_start()
  @doc """
  starts a supervised TFTP service.

  `srv_module` should be a module that implements the `Trivial.Server`
  behaviour; `srv_init` is the initial data given to the child processes.

  ### Options

  - `:trivial_name`: name given to the trivial server.
    *Defaults to `Trivial`*
  """
  def start_link(srv_module, srv_init, opts) do
    start_link({srv_module, srv_init, opts})
  end

  @doc false
  # convenience function for easy supervision.
  @spec start_link(t) :: Supervisor.on_start
  def start_link(arg_tuple = {_, _, opts}) do
    name = opts[:trivial_name] || __MODULE__

    Supervisor.start_link(
      __MODULE__,
      arg_tuple,
      name: name)
  end

  @impl true
  def init({server_module, server_init, opts}) do

    children = [{Daemon,
      {server_module,
       server_init,
       Keyword.put(opts, :supervisor, self())}},
      {DynamicSupervisor, strategy: :one_for_one}]

    Supervisor.init(children, strategy: :one_for_all)
  end

  ##############################################################
  ## API

  @spec daemon(Supervisor.supervisor) :: pid
  @doc """
  retrieves the PID of the `Trivial.Daemon` process being supervised
  by the target supervisor.
  """
  def daemon(supervisor \\ __MODULE__) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {Daemon, pid, :worker, _} -> pid
      _ -> false
    end)
  end

  @spec server_supervisor(Supervisor.supervisor) :: pid
  @doc """
  retrieves the PID of the `DynamicSupervisor` process being
  supervised by the target supervisor.
  """
  def server_supervisor(supervisor \\ __MODULE__) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {DynamicSupervisor, pid, :supervisor, _} -> pid
      _ -> false
    end)
  end

  @spec port(Supervisor.supervisor) :: pos_integer
  @doc """
  retrieves the UDP port of the daemon process.
  """
  def port(supervisor \\ __MODULE__) do
    supervisor |> daemon |> port
  end

end
