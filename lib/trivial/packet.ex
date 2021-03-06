defmodule Trivial.Packet do

  @moduledoc """
  Code for converting structured erlang data into a udp packet
  which is then sent over the udp connection in a `Trivial.Conn`
  struct.
  """

  alias Trivial.Conn

  @errorcodes %{
    error:     0,
    enoent:    1,
    eacces:    2,
    enotsup:   4,
    einval:    5,
    enouser:   7
  }

  @typedoc """
  POSIX atom terms to describe transaction errors.

  The following definitions are from
  [RFC 1350](https://tools.ietf.org/html/rfc1350) Appendix I (p. 9)

  ```text
  atom        value     meaning

  :error      0         Not defined, see error message (if any).
  :enoent     1         File not found.
  :eacces     2         Access violation.
  -           3         Disk full or allocation exceeded.
  :enotsup    4         Illegal TFTP operation.
  :eninval    5         Unknown transfer ID.
  -           6         File already exists.
  :enouser    7         No such user.
  ```
  """

  @type error_codes ::
    :error | :enoent | :eacces| :enotsup| :einval| :enouser

  @typedoc "structured data representing an error response"
  @type error_def :: {:error, error_codes, iodata}
  @typedoc "structured data representing a data response"
  @type data_def :: {:data, block_id::non_neg_integer, iodata}
  @typedoc "structured data for connection responses"
  @type packet_def :: data_def | error_def | :oack

  #############################################################################
  # API

  @spec send(Conn.t, packet_def) :: any
  @doc """
  converts a structured erlang term and sends the corresponding TFTP packet
  over an open udp socket
  """
  def send(conn, {:data, block, data}) do
    do_send_data(conn, block, data)
  end
  def send(conn, {:error, code, msg}) do
    do_send_error(conn, code, msg)
  end
  def send(conn, :oack) do
    do_send_oack(conn)
  end

  #  2 bytes     2 bytes      n bytes
  #  ----------------------------------
  # | Opcode |   Block #  |   Data     |
  #  ----------------------------------
  #
  #       Figure 5-2: DATA packet
  # Data is actually transferred in DATA packets depicted in Figure 5-2.
  # DATA packets (opcode = 3) have a block number and data field.  The
  # block numbers on data packets begin with one and increase by one for
  # each new block of data.  This restriction allows the program to use a
  # single number to discriminate between new packets and duplicates.
  # The data field is from zero to 512 bytes long.  If it is 512 bytes
  # long, the block is not the last block of data; if it is from zero to
  # 511 bytes long, it signals the end of the transfer.  (See the section
  # on Normal Termination for details.)

  @data <<0, 3>>
  defp do_send_data(conn, block, data) do
    :gen_udp.send(
      conn.socket,
      conn.client_ip,
      conn.client_port, [@data, <<block::16>>, data])
  end

  @error <<0, 5>>
  defp do_send_error(conn, error, errormsg) do
    :gen_udp.send(
      conn.socket,
      conn.client_ip,
      conn.client_port,
      [@error, <<@errorcodes[error]::16>>, errormsg, 0]
    )
  end

  @supported_options [:blksize, :timeout, :tsize]
  # The OACK packet has the following format:
  #
  #   +-------+---~~---+---+---~~---+---+---~~---+---+---~~---+---+
  #   |  opc  |  opt1  | 0 | value1 | 0 |  optN  | 0 | valueN | 0 |
  #   +-------+---~~---+---+---~~---+---+---~~---+---+---~~---+---+
  #   opc
  #      The opcode field contains a 6, for Option Acknowledgment.
  #   opt1
  #      The first option acknowledgment, copied from the original
  #      request.
  #   value1
  #      The acknowledged value associated with the first option.  If
  #      and how this value may differ from the original request is
  #      detailed in the specification for the option.
  #   optN, valueN
  #      The final option/value acknowledgment pair.

  @oack <<0, 6>>
  defp do_send_oack(conn) do
    opcodes = Enum.flat_map(@supported_options, fn option ->
      val = Map.get(conn, option)
      if val do  # if the option hasn't been set, don't set it.
        [Atom.to_string(option), 0, "#{val}", 0]
      else
        []
      end
    end)

    :gen_udp.send(
      conn.socket,
      conn.client_ip,
      conn.client_port,
      IO.iodata_to_binary([@oack, opcodes]))
  end

end
