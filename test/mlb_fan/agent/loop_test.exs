defmodule MlbFan.Agent.LoopTest do
  use MlbFan.DataCase, async: false

  @moduletag :db

  import Ecto.Query

  alias MlbFan.Agent.Loop
  alias MlbFan.Llm.Schemas.LlmUsage
  alias MlbFan.Mlb.Schemas.HomeRunEvent
  alias MlbFan.Repo
  alias MlbFan.TestFixtures

  setup do
    prev = Application.get_env(:mlb_fan, :anthropic_api_key)
    Application.put_env(:mlb_fan, :anthropic_api_key, "test-key")
    on_exit(fn -> Application.put_env(:mlb_fan, :anthropic_api_key, prev) end)
    :ok
  end

  # SSE for turn 1: emit a single get_homers_by_date tool_use.
  defp turn1_sse do
    """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_t1","usage":{"input_tokens":2100,"cache_read_input_tokens":0,"cache_creation_input_tokens":2000,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_a","name":"get_homers_by_date","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"date\\":\\"2026-07-02\\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":30}}

    event: message_stop
    data: {"type":"message_stop"}

    """
  end

  # SSE for turn 2: final answer text (no disclaimer — loop appends it).
  defp turn2_sse do
    """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_t2","usage":{"input_tokens":5000,"cache_read_input_tokens":2000,"cache_creation_input_tokens":0,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Two players homered on 2026-07-02."}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":900}}

    event: message_stop
    data: {"type":"message_stop"}

    """
  end

  # SSE that always returns tool_use (get_schedule) so the loop keeps cycling.
  defp always_tool_use_sse do
    """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_cap","usage":{"input_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_cap","name":"get_schedule","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"date\\":\\"2026-07-02\\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":10}}

    event: message_stop
    data: {"type":"message_stop"}

    """
  end

  test "loop cap at max_loop_iterations exits with a diagnostic message" do
    # Override to 3 iterations so the test runs fast.
    prev_cfg = Application.get_env(:mlb_fan, :agent, [])
    Application.put_env(:mlb_fan, :agent, max_loop_iterations: 3)
    on_exit(fn -> Application.put_env(:mlb_fan, :agent, prev_cfg) end)

    Req.Test.stub(MlbFan.ReqStub, fn conn ->
      cond do
        conn.host =~ "anthropic" ->
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, always_tool_use_sse())

        # The schedule tool needs an HTTP stub too
        true ->
          Req.Test.json(conn, %{"dates" => []})
      end
    end)

    messages = [%{"role" => "user", "content" => "loop cap test"}]

    assert {:ok, result} =
             Loop.run(messages, session_id: "cap_sess", question_label: "freeform")

    assert result.stop_reason == "max_iterations"
    # Diagnostic text contains the key phrase from the spec
    assert result.text =~ "tool-call limit"
    # Exactly max_iterations llm_usage rows were recorded
    usage = Repo.all(from u in LlmUsage, where: u.session_id == "cap_sess")
    assert length(usage) == 3
  end

  test "the tool-use loop dispatches a tool via the MCP client and terminates with a final answer" do
    {:ok, turn} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(MlbFan.ReqStub, fn conn ->
      cond do
        conn.host =~ "anthropic" ->
          n = Agent.get_and_update(turn, fn t -> {t, t + 1} end)
          body = if n == 0, do: turn1_sse(), else: turn2_sse()

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, body)

        String.contains?(conn.request_path, "/schedule") ->
          Req.Test.json(conn, TestFixtures.schedule_body(date: "2026-07-02"))

        String.contains?(conn.request_path, "/playByPlay") ->
          Req.Test.json(conn, TestFixtures.playbyplay_body())

        true ->
          Req.Test.json(conn, %{})
      end
    end)

    messages = [%{"role" => "user", "content" => "Who homered on 2026-07-02?"}]

    assert {:ok, result} =
             Loop.run(messages, session_id: "sess_test", question_label: "hrs_yesterday")

    # Loop terminated with the final answer + the server-side disclaimer safety-net.
    assert result.stop_reason == "end_turn"
    assert result.text =~ "Two players homered"
    assert result.text =~ "1-800-GAMBLER"

    # The tool actually executed (HR events mirrored).
    assert Repo.aggregate(from(h in HomeRunEvent), :count) == 2

    # Two llm_usage turns recorded under a single logical message id.
    usage = Repo.all(from u in LlmUsage, where: u.session_id == "sess_test")
    assert length(usage) == 2
    assert usage |> Enum.map(& &1.message_id) |> Enum.uniq() |> length() == 1
    assert Enum.map(usage, & &1.turn_index) |> Enum.sort() == [0, 1]
  end
end
