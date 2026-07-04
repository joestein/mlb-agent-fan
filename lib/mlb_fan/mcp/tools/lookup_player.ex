defmodule MlbFan.Mcp.Tools.LookupPlayer do
  @moduledoc "Resolve a player name to their MLB person id and basic bio (position, bats/throws, team). Use before other tools when you only have a name."
  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response
  alias MlbFan.Stats

  schema do
    field :name, {:required, :string}, description: "Full or partial player name."
  end

  @impl true
  def execute(params, frame), do: {:reply, Response.json(Response.tool(), run(params)), frame}

  def run(params) do
    name = params["name"] || params[:name]

    if is_binary(name) and name != "" do
      Stats.lookup_player(name)
    else
      %{"error" => "name is required"}
    end
  end
end
