defmodule MlbFan.Agent.RunTurnAction do
  @moduledoc """
  Jido action that runs one MLB Fan Agent conversation turn. Per spec §15 R2
  (pre-approved fallback), the Jido agent owns/drives the MCP client while the
  Anthropic tool-use loop lives in `MlbFan.Agent.Loop`; this action is the
  Jido-facing entry point that invokes it.
  """
  use Jido.Action,
    name: "mlb_fan_run_turn",
    description: "Run one MLB Fan Agent turn: the Anthropic tool-use loop over the MCP client.",
    schema: [
      messages: [type: {:list, :map}, required: true, doc: "Anthropic message history"],
      session_id: [type: :string, default: "anon"],
      question_label: [type: :string, default: "freeform"]
    ]

  alias MlbFan.Agent.Loop

  @impl true
  def run(params, _context) do
    Loop.run(params.messages,
      session_id: params.session_id,
      question_label: params.question_label
    )
  end
end
