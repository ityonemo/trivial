defmodule Trivial.Conn do
  @moduledoc """
  struct for tftp connection negotiation.

  From [rfc1350](https://tools.ietf.org/html/rfc1350) Section 2:

  > A transfer is established by sending a request (WRQ to write onto a
  > foreign file system, or RRQ to read from it), and receiving a
  > positive reply, an acknowledgment packet for write, or the first data
  > packet for read.  In general an acknowledgment packet will contain
  > the block number of the data packet being acknowledged.  Each data
  > packet has associated with it a block number; block numbers are
  > consecutive and begin with one.  Since the positive response to a
  > write request is an acknowledgment packet, in this special case the
  > block number will be zero.  (Normally, since an acknowledgment packet
  > is acknowledging a data packet, the acknowledgment packet will
  > contain the block number of the data packet being acknowledged.)  If
  > the reply is an error packet, then the request has been denied.
  >
  > In order to create a connection, each end of the connection chooses a
  > TID for itself, to be used for the duration of that connection.  The
  > TID's chosen for a connection should be randomly chosen, so that the
  > probability that the same number is chosen twice in immediate
  > succession is very low.  Every packet has associated with it the two
  > TID's of the ends of the connection, the source TID and the
  > destination TID.  These TID's are handed to the supporting UDP (or
  > other datagram protocol) as the source and destination ports.  A
  > requesting host chooses its source TID as described above, and sends
  > its initial request to the known TID 69 decimal (105 octal) on the
  > serving host.  The response to the request, under normal operation,
  > uses a TID chosen by the server as its source TID and the TID chosen
  > for the previous message by the requestor as its destination TID.
  > The two chosen TID's are then used for the remainder of the transfer.
  """

  defstruct [:mode, :filename,
    :client_ip, :client_port, :daemon, :srv_pid, :srv_port, :ref, :socket,
    :module, :data, :blksize, :timeout, :tsize]

  @type t :: %__MODULE__{
    mode:        :read | :write,
    filename:    String.t,
    client_ip:   :inet.ip_address,
    client_port: :inet.port_number,
    daemon:      pid,
    srv_port:    :inet.port_number,
    srv_pid:     pid,
    ref:         reference,
    socket:      port | nil,
    module:      module,
    data:        term,
    blksize:     non_neg_integer | nil,
    timeout:     non_neg_integer | nil,
    tsize:       true | nil
  }

  require Logger

  @rrq <<1::16>>
  @wrq <<2::16>>

  @spec from_request(tuple, {module, term}) :: {:ok, t} | {:error, :eacces}
  @doc """
  converts an erlang UDP struct to a request struct.

  From rfc1350 (p 8):

  ```
            2 bytes    string   1 byte     string   1 byte
          -----------------------------------------------
   RRQ/  | 01/02 |  Filename  |   0  |    Mode    |   0  |
   WRQ    -----------------------------------------------
  ```

  this library will only accept read requests.
  """
  def from_request({:udp, _port, client_ip, client_port, @rrq <> xmit_binary}, {module, data}) do
    # pick a random transmission id in the 16-bit range.
    {filename, unparsed_options} = case String.split(xmit_binary, <<0>>) do
      [filename, "octet" | unparsed_options] -> {filename, unparsed_options}
      [filename, "netascii" | unparsed_options] -> {filename, unparsed_options}
    end

    conn = struct(__MODULE__,
      mode:        :read,
      filename:    filename,
      client_ip:   client_ip,
      client_port: client_port,
      daemon:      self(),
      srv_port:    0,
      ref:         make_ref(),
      module:      module,
      data:        data)

    {:ok, parse_options(conn, unparsed_options)}
  end
  def from_request({:udp, _port, _cip, _cpt, @wrq <> _}, _) do
    {:error, :eacces}
  end

  @doc """

  Note that from [rfc 2347](https://tools.ietf.org/html/rfc2348) (p 2):

  > Options are appended to a TFTP Read Request or Write Request packet
  > as follows:

  ```
  +-------+---~~---+---+---~~---+---+---~~---+---+---~~---+---+-->
  |  opc  |filename| 0 |  mode  | 0 |  opt1  | 0 | value1 | 0 | <
  +-------+---~~---+---+---~~---+---+---~~---+---+---~~---+---+-->

   >-------+---+---~~---+---+
  <  optN  | 0 | valueN | 0 |
   >-------+---+---~~---+---+
  ```

  - blocksize option is defined in [rfc 2348](https://tools.ietf.org/html/rfc2348)
  - timeout option is defined in [rfc 2349](https://tools.ietf.org/html/rfc2348)
  - tsize option is defined in [rfc 2349](https://tools.ietf.org/html/rfc2348)

  """
  def parse_options(conn, []), do: conn
  def parse_options(conn, ["blksize", blksize | rest]) do
    Logger.debug("#{:inet.ntoa conn.client_ip} requests a block size #{blksize}b")
    parse_options(struct(conn, blksize: String.to_integer(blksize)), rest)
  end
  def parse_options(conn, ["timeout", timeout | rest]) do
    Logger.debug("#{:inet.ntoa conn.client_ip} sets the timeout to #{timeout}s")
    # note that rfc 2349 specifies timeout in seconds.  for convenience
    # we convert this to milliseconds.
    parse_options(struct(conn, timeout: String.to_integer(timeout) * 1000), rest)
  end
  def parse_options(conn, ["tsize", "0" | rest]) do
    # note that a tsize read request MUST have a payload of 0.
    Logger.debug("#{:inet.ntoa conn.client_ip} requests a transfer size response")
    # if we request a size for the transfer, we should query the parent module.
    parse_options(struct(conn, tsize: true), rest)
  end
  def parse_options(conn, ["" | rest]), do: parse_options(conn, rest)
  def parse_options(conn, [option | rest]) do
    Logger.warn("unhandled option from #{:inet.ntoa conn.client_ip}: #{inspect option}")
    parse_options(conn, rest)
  end

end
