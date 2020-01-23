defmodule Trivial.Daemon do
  @moduledoc """
  UDP Daemon for the TFTP protocol.  Listens on a port for "accept"-style UDP
  connections, then spawns a server to handle the continued processing of the
  results.

  You should use this module directly to start up a TFTP service if you don't
  necessarily want a supervision tree, for example, in tests.  The daemon and
  server processes, will still be linked, so an error will bring down the
  entire Daemon instance.

  ## Example

  The following code starts up a TFTP service on a free udp port and
  retrieves the udp port so that you can run tests against the functionality
  of MyModule:

  ```
  {:ok, daemon} = Trivial.Daemon.start_link(MyModule, initial_value, port: 0)
  dest_port = Trivial.Daemon.port(daemon)
  ```

  If you are testing components with `Mox`, be sure to link the
  daemon process to your test process with specific allowances.
  """

  defstruct [:port,          # UDP Port to listen to
             :socket,        # accept-socket
             :init,          # initial value for all servers
             :supervisor,    # parent supervisor identity.
             servers: %{}]   # child servers and who they connect to

  @typep t :: %{
    port:       :inet.port_number,
    socket:     :gen_udp.socket,
    init:       term,
    supervisor: pid,
    servers:    %{optional(:inet.address) => Conn.t}
  }

  use GenServer

  require Logger
  alias Trivial.{Conn, Packet, Server}

  #############################################################################
  ## LAUNCH BOOTSTRAPPING BOILERPLATE

  @spec start_link({module, term, keyword}) :: GenServer.on_start
  @doc false
  # internal API for easy calling when building supervision trees.
  def start_link({server_mod, server_init, opts}) do
    start_link(server_mod, server_init, opts)
  end

  @spec start_link(module, term, keyword) :: GenServer.on_start
  @doc """
  starts a daemon.

  ## Options:
  - `port`: UDP port to open for transactions.  Note that a value of 0 will
    select a random, available port.  You may then discover this port by calling
    `port/1`. On some systems, you may be restricted to ports above 1024; as the
    default TFTP port is 69, an empty value will not automatically be usable in
    the standard fashion.  See `Trivial` for deployment strategies.

    *Defaults to UDP port 6969*
  """
  def start_link(server_mod, server_init, opts) do
    gen_server_opts = opts
    |> Keyword.take([:name])
    |> Keyword.put_new(:name, server_mod)

    opts = Keyword.put(opts, :init, {server_mod, server_init})
    GenServer.start_link(__MODULE__, opts, gen_server_opts)
  end

  @impl true
  @spec init(keyword) :: {:ok, t} | {:stop, any}
  def init(opts) do
    port = opts[:port] || 6969
    extra_opts = Keyword.take(opts, [:bind_to_device])

    with {:ok, socket} <- :gen_udp.open(port, [:binary, active: true] ++ extra_opts),
         {:ok, port} <- :inet.port(socket) do
      {:ok, struct(__MODULE__, Keyword.merge(opts, [port: port, socket: socket]))}
    else
      reason ->
        {:stop, reason}
    end
  end

  #############################################################################
  ## API

  @doc """
  a query to find out the UDP port which the daemon is listening to.  Mostly
  useful for testing.
  """
  def port(daemon), do: GenServer.call(daemon, :port)
  defp port_impl(state), do: {:reply, state.port, state}

  @spec server_supervisor(GenServer.server) :: pid
  @doc false
  # entirely an internal convenience call.  Mostly used by daemon
  # to be able to hook child servers into the supervision tree, under
  # the dynamic supervisor.
  def server_supervisor(daemon) when is_atom(daemon) or is_pid(daemon) do
    GenServer.call(daemon, :server_supervisor)
  end
  # for calls COMING FROM INSIDE THE BUILDING
  def server_supervisor(%__MODULE__{supervisor: supervisor}) do
    # this should punt to asking Trivial.
    Trivial.server_supervisor(supervisor)
  end
  # punt to a local call.  (the call trace here is a bit
  # spaghetti-ish, so be careful!)
  defp server_supervisor_impl(state) do
    {:reply, server_supervisor(state), state}
  end

  @spec register(Conn.t) :: :ok
  @doc false
  # used by a child server to inform the daemon that it exists.
  def register(conn) do
    GenServer.call(conn.daemon, {:register, {self(), conn}})
  end
  defp register_impl({server, conn}, state) do
    Logger.debug("registering #{inspect server} for #{conn.srv_port} -> #{:inet.ntoa conn.client_ip}:#{conn.client_port}")
    Process.monitor(server)
    new_servers = Map.put(state.servers, server, conn)
    {:reply, :ok, %{state | servers: new_servers}}
  end

  #############################################################################
  ## UDP message handling.

  defp udp_impl(request = {:udp, _, _, _, _}, state) do
    case Conn.from_request(request, state.init) do
      {:ok, conn} ->
        start_server(conn, state.supervisor)
      _ -> :error #but don't care, for now
    end
    {:noreply, state}
  end

  # handles the case when we are in a supervision tree
  # and the case when we are not.
  defp start_server(conn, nil) do
    Server.start_link(conn)
  end
  defp start_server(conn, supervisor) when is_pid(supervisor) do
    supervisor
    |> Trivial.server_supervisor()
    |> DynamicSupervisor.start_child({Server, conn})
  end

  #############################################################################
  ## cleanup is responsible for reopening the udp port of the child and
  ## sending an error signal back to the waiting client.

  defp cleanup_impl({:DOWN, _, :process, pid, :normal}, state) do
    # if it ended normally we don't have to send anything back to the client,
    # just go ahead and remove it from state tracking.
    {:noreply, %{state | servers: Map.delete(state.servers, pid)}}
  end
  defp cleanup_impl({:DOWN, _, :process, pid, _}, state) do
    # sleep for a short bit to let the udp handlers recycle
    #Process.sleep(50)
    server_data = state.servers[pid]
    with {:ok, socket} <- :gen_udp.open(server_data.srv_port) do
      miniconn = Map.put(state.servers[pid], :socket, socket)
      Packet.send(miniconn, {:error, :error, "connection lost"})
      :gen_udp.close(socket)
    end
    {:noreply, %{state | servers: Map.delete(state.servers, pid)}}
  end

  #############################################################################
  ## router

  @impl true
  def handle_info(message = {:udp, _, _, _, _}, state) do
    udp_impl(message, state)
  end
  def handle_info(message = {:DOWN, _, :process, _, _}, state) do
    cleanup_impl(message, state)
  end
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:port, _from, state), do: port_impl(state)
  def handle_call({:register, what}, _from, state) do
    register_impl(what, state)
  end
  def handle_call(:server_supervisor, _from, state) do
    server_supervisor_impl(state)
  end

end
