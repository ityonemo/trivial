defmodule Trivial do
  use Supervisor

  alias Trivial.Daemon

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
  def start_link(srv_module, srv_init, opts) do
    start_link({srv_module, srv_init, opts})
  end

  @doc false
  @spec start_link(t) :: Supervisor.on_start
  def start_link(arg_tuple = {_, _, opts}) do
    name = opts[:trivial_name] || __MODULE__

    Supervisor.start_link(
      __MODULE__,
      arg_tuple,
      name: name)
  end

  @doc false
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
  def daemon(supervisor \\ __MODULE__) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {Daemon, pid, :worker, _} -> pid
      _ -> false
    end)
  end

  @spec server_supervisor(Supervisor.supervisor) :: pid
  def server_supervisor(supervisor \\ __MODULE__) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {DynamicSupervisor, pid, :supervisor, _} -> pid
      _ -> false
    end)
  end

  @spec port(Supervisor.supervisor) :: pos_integer
  def port(supervisor \\ __MODULE__) do
    supervisor |> daemon |> port
  end

end
