defmodule Trivial.Daemon do

  @moduledoc """
  UDP Daemon for the TFTP protocol.  Listens on a port for "accept"-style UDP
  connections, then spawns a server to handle the continued processing of the
  results.
  """

  defstruct [:port,          # UDP Port to listen to
             :socket,        # accept-socket
             :init,          # initial value for all servers
             :supervisor,    # parent supervisor identity.
             servers: %{}]   # child servers and who they connect to

  use GenServer

  require Logger

  alias Trivial.{Conn, Packet, Server}

  #############################################################################
  ## LAUNCH BOOTSTRAPPING BOILERPLATE

  def start_link({server_mod, server_init, opts}) do
    start_link(server_mod, server_init, opts)
  end

  def start_link(server_mod, server_init, opts) do
    gen_server_opts = opts
    |> Keyword.take([:name])
    |> Keyword.put_new(:name, server_mod)

    opts = Keyword.put(opts, :init, {server_mod, server_init})
    GenServer.start_link(__MODULE__, opts, gen_server_opts)
  end

  @impl true
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
  def server_supervisor(daemon) when is_atom(daemon) or is_pid(daemon) do
    GenServer.call(daemon, :server_supervisor)
  end
  # for internal calls
  def server_supervisor(%__MODULE__{supervisor: supervisor}) do
    # this should punt to asking Trivial.
    Trivial.server_supervisor(supervisor)
  end
  defp server_supervisor_impl(state) do
    {:reply, server_supervisor(state), state}
  end

  @spec register(Conn.t) :: :ok
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
  ## sending an error signal.

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
  def handle_info(msg, state) do
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
