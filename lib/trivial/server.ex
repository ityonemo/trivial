defmodule Trivial.Server do

  @moduledoc """
  A genserver which handles data packet transfers between the TFTP service
  and hungry clients.  By being spawned off of `Trivial.Daemon` after accept,
  it allows transactions to be concurrent and asynchronous.

  Generally, you should not be initiating from this module, except possibly
  for testing puroposes.

  This module also serves as a behaviour module defining the API that you
  should use to service TFTP transactions.

  ## Example

  The following example shows how to set up a TFTP module which can
  transmit both templated and file data.  Note that in general, you should
  not use stateful reading techinques in the `read/5` callback since UDP
  has no delivery guarantees and the client may re-request a data block,
  meaning that your data transmission may be nonlinear.

  ```
  defmodule MyTftpModule do
    @behaviour Trivial.Server

    @impl true
    # forbids transactions from the evil ip address 42.42.42.42
    def init(_, {42, 42, 42, 42}, _), do: {:error, :eacces}
    # forbids transactions to unwanted files
    def init("secret.txt", _client, _), do: {:error, :eacces}

    # set up a templated transaction
    def init("/templated", _client, data) do
      str = "template for \#{inet.ntoa client}"
      size = :erlang.size(str)
      {:ok, {str, size}}
    end

    # set up file transaction
    def init(file, _client, data) do
      bin = File.read!(file)
      size = :erlang.size(bin)
      {:ok, {bin, size}}
    end

    @impl true
    def read(_request, pos, len, _client, data = {str, size}) when pos > size do
      :done
    end
    def read(_request, pos, len, _client, data = {str, size}) pos + len > size do
      {:ok, :erlang.binary_part(str, pos, size - pos), data}
    end
    def read(_request, pos, len, _client, data = {str, size}) do
      {:ok, :erlang.binary_part(str, pos, len), data}
    end

    @impl true
    def tsize(_request, _client, data = {_, size}) do
      {:ok, size, data}
    end
  end
  ```
  """

  use GenServer

  alias Trivial.{Conn, Daemon, Packet}

  require Logger

  @spec start_link(Conn.t) :: GenServer.on_start
  @doc """
  starts up a TFTP server that wraps a single set of connection details.
  """
  def start_link(conn) do
    GenServer.start_link(__MODULE__, conn)
  end

  ###########################################################################
  ## Initialization and bootstrap chain.

  @impl true
  @spec init(Conn.t) :: {:ok, Conn.t, {:continue, atom}} | {:stop, atom}
  def init(conn = %{module: module}) do
    with {:ok, socket} <- :gen_udp.open(0, [:binary, active: true]),
         {:ok, port} <- :inet.port(socket) do

      new_conn = struct(conn,
        srv_pid: self(),
        srv_port: port,
        socket: socket,
        module: module)

      {:ok, new_conn, {:continue, :initialization}}
    else
      reason ->
        Logger.error("error initializing #{conn.filename}")
        {:stop, reason, conn}
    end
  end

  @default_blksize 512

  @typep continuations :: :initialization | :first_data

  @impl true
  @spec handle_continue(continuations, Conn.t) :: {:noreply, Conn.t} | {:stop, atom, Conn.t}
  def handle_continue(:initialization, conn = %{module: module}) do
    # registration needs to happen out of band of the init process, because
    # we need to hear back from the Daemon.  This avoids a deadlock.
    # module initialization is also potentially slow, so we shouldn't hold up
    # the daemon for that reason, either.  Finally, we should register first,
    # then initialize, because potentially initializing can crash our
    # process.
    with :ok <- Daemon.register(conn),
         {:ok, data} <- module.init(conn.filename, conn.client_ip, conn.data) do
      {:noreply, %{conn | data: data}, {:continue, :first_data}}
    else
      {:error, reason} ->
        {:stop, reason, conn}
      _ -> {:stop, :error, conn}
    end
  end

  def handle_continue(:first_data, conn = %{blksize: nil, timeout: nil, tsize: nil}) do
    # in the case when any of the optional values are set, go directly to the
    # a data response.
    read_and_send(conn, 0)
  end
  def handle_continue(:first_data, conn = %{module: module, tsize: true}) do
    case module.tsize(conn.filename, conn.client_ip, conn.data) do
      {:ok, tsize, new_data} ->
        handle_continue(:first_data, %{conn | tsize: tsize, data: new_data})
      {:error, reason, msg, new_data} ->
        new_conn = %{conn | data: new_data}
        Packet.send(new_conn, {:error, reason, msg})
        # stop normally because we are controlling the
        # error output to the client
        {:stop, :normal, new_conn}
    end
  end
  def handle_continue(:first_data, conn) do
    # send a oack response
    Packet.send(conn, :oack)
    {:noreply, conn}
  end

  # general "read and send" message that is used by both
  # the first data continuation and general packet sending.
  @spec read_and_send(Conn.t, non_neg_integer) ::
    {:noreply, Conn.t} | {:stop, atom, Conn.t}
  defp read_and_send(conn = %{module: module}, index) do
    blksize = conn.blksize || @default_blksize
    case module.read(conn.filename, blksize * index, blksize, conn.client_ip, conn.data) do
      {:ok, data_to_send, new_data} ->
        Logger.debug("sending #{:inet.ntoa conn.client_ip} #{conn.filename} block #{index + 1} bytes #{:erlang.size(data_to_send)}")
        Packet.send(conn, {:data, index + 1, data_to_send})
        {:noreply, %{conn | data: new_data}}
      :done ->
        {:stop, :normal, conn}
      {:error, reason, msg, new_data} ->
        # stop normally because we are controlling the
        # error output to the client
        Packet.send(conn, {:error, reason, msg})
        {:stop, :normal, %{conn | data: new_data}}
    end
  end

  #############################################################################
  ## API

  @spec port(GenServer.server) :: :inet.port_number
  @doc """
  used to retrieve the open port that is being used for the transaction.  This
  is synonomyous to `TID` in RFC 1350.
  """
  def port(svr), do: GenServer.call(svr, :port)
  @spec port_impl(Conn.t) :: {:reply, :inet.port_number, Conn.t}
  defp port_impl(conn), do: {:reply, conn.srv_port, conn}

  @ack 4
  @err 5

  @impl true
  def handle_info({:udp, _, client_ip, client_port, <<@ack::16, index::16>>},
       conn = %{client_ip: client_ip, client_port: client_port}) do
    Logger.debug("client #{:inet.ntoa client_ip} acknowledeges index #{index}")
    read_and_send(conn, index)
  end
  def handle_info({:udp, _, client_ip, client_port, <<@err::16, index::16>> <> msg},
       conn = %{client_ip: client_ip, client_port: client_port}) do
    msg = String.trim(msg)
    Logger.error("client #{:inet.ntoa client_ip} reports error #{index}, message: #{msg}")
    {:stop, :client_error, conn}
  end
  def handle_info({:udp, _, client_ip, client_port, binary},
       conn = %{client_ip: client_ip, client_port: client_port}) do
    Logger.warn("unusual binary found from #{:inet.ntoa client_ip}: #{inspect binary}")
    {:stop, :client_error, conn}
  end
  def handle_info({:udp, _, client_ip, _, _}, conn) do
    Logger.warn("stray packet received from #{:inet.ntoa client_ip}")
    {:stop, :client_error, conn}
  end

  @impl true
  def handle_call(:port, _from, conn), do: port_impl(conn)

  #############################################################################
  ## Callbacks

  @doc """
  called after the TFTP transaction request has been made to to the server,
  but before any further messages have been passed between the client and
  the server.  Most stateful setup and teardown should occur here.
  """
  @callback init(
    request :: Path.t,
    client :: :inet.address,
    data) :: {:ok, data} | :error | {:error, Packet.error_codes} when data: term

  @doc """
  called when the TFTP server needs to deliver another data packet to the
  client.
  """
  @callback read(
    request::Path.t,
    position :: non_neg_integer,
    size :: non_neg_integer,
    client :: :inet.address,
    data) ::
      {:ok, binary, data}
      | :done
      | {:error, type::atom, String.t, data}
      when data: term


  @doc """
  called if the TFTP client has requested to know the size of the content
  ahead of time.

  Your `read/5` calls should respect this value as a maximum size limit
  to your content payload
  """
  @callback tsize(
    request::Path.t,
    client:: :inet.address,
    data) ::
      {:ok, non_neg_integer, data}
      | {:error, reason::atom, String.t, data}
      when data: term
end
