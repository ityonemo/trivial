defmodule TrivialStub do

  @behaviour Trivial.Server

  @impl true
  def init("init_error!", _, _conn), do: :error
  def init(_, _, any), do: {:ok, any}

  @impl true
  # set a crash handler.
  def read("crash!", _pos, _len, _client, _data) do
    raise "crashed!"
  end
  # set a error handler.
  def read("error!", _pos, _len, _client, data) do
    {:error, :enoent, "error! file not found", data}
  end
  def read(_filename, pos, len, _client, data) when :erlang.size(data) >= pos + len do
    {:ok, :binary.part(data, pos, len), data}
  end
  def read(_filename, pos, _len, _client, data) do
    {:ok, :binary.part(data, pos, :erlang.size(data) - pos), data}
  end

  @impl true
  def tsize(_filename, _client, data) do
    {:ok, :erlang.size(data), data}
  end
end
