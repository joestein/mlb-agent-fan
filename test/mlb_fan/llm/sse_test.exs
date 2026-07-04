defmodule MlbFan.Llm.SseTest do
  use ExUnit.Case, async: true

  alias MlbFan.Llm.{Anthropic, Sse}

  # A realistic two-block stream: one text block, then a tool_use block whose
  # input JSON arrives across several input_json_delta events.
  @stream """
  event: message_start
  data: {"type":"message_start","message":{"id":"msg_123","usage":{"input_tokens":2000,"cache_read_input_tokens":1800,"cache_creation_input_tokens":0,"output_tokens":1}}}

  event: content_block_start
  data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

  event: content_block_delta
  data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello "}}

  event: content_block_delta
  data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}

  event: content_block_stop
  data: {"type":"content_block_stop","index":0}

  event: content_block_start
  data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"get_homers_by_date","input":{}}}

  event: content_block_delta
  data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"date\\":"}}

  event: content_block_delta
  data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"2026-07-02\\"}"}}

  event: content_block_stop
  data: {"type":"content_block_stop","index":1}

  event: message_delta
  data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}

  event: message_stop
  data: {"type":"message_stop"}
  """

  defp run(chunks, collector \\ fn _ -> :ok end) do
    {events, _state} =
      Enum.reduce(chunks, {[], Sse.new()}, fn chunk, {acc, st} ->
        {evs, st2} = Sse.feed(st, chunk)
        {acc ++ evs, st2}
      end)

    Anthropic.apply_events(Anthropic.initial_state(), events, collector)
  end

  test "parses a full stream fed as one chunk" do
    result = run([@stream]) |> then(&finalize/1)

    assert result.message_id == "msg_123"
    assert result.stop_reason == "tool_use"
    assert result.usage.input_tokens == 2000
    assert result.usage.cache_read_input_tokens == 1800
    assert result.usage.output_tokens == 42

    assert %{"type" => "text", "text" => "Hello world"} = Enum.at(result.content, 0)

    assert %{
             "type" => "tool_use",
             "name" => "get_homers_by_date",
             "input" => %{"date" => "2026-07-02"}
           } =
             Enum.at(result.content, 1)
  end

  test "handles events split across arbitrary TCP-chunk boundaries" do
    # Split the stream into 40-byte chunks to force mid-line/mid-event splits.
    chunks = for <<c::binary-size(40) <- @stream>>, do: c

    remainder =
      binary_part(@stream, div(byte_size(@stream), 40) * 40, rem(byte_size(@stream), 40))

    chunks = chunks ++ [remainder]

    result = run(chunks) |> then(&finalize/1)

    assert %{"input" => %{"date" => "2026-07-02"}} = Enum.at(result.content, 1)
    assert result.stop_reason == "tool_use"
  end

  test "streams text deltas to the collector in order" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    run([@stream], fn text -> Agent.update(agent, &[text | &1]) end)
    tokens = Agent.get(agent, & &1) |> Enum.reverse()
    assert Enum.join(tokens) == "Hello world"
  end

  # ── stop_reason paths (spec §6.3) ────────────────────────────────────────

  defp stop_reason_stream(reason) do
    """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_sr","usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"text"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"#{reason}"},"usage":{"output_tokens":5}}

    event: message_stop
    data: {"type":"message_stop"}
    """
  end

  for reason <- ~w(end_turn max_tokens refusal pause_turn) do
    test "stop_reason #{reason} is captured from message_delta" do
      result = run([stop_reason_stream(unquote(reason))]) |> then(&finalize/1)
      assert result.stop_reason == unquote(reason)
    end
  end

  # ── thinking_delta accumulation (spec §6.3) ──────────────────────────────

  @thinking_stream """
  event: message_start
  data: {"type":"message_start","message":{"id":"msg_think","usage":{"input_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}}

  event: content_block_start
  data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

  event: content_block_delta
  data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me analyze..."}}

  event: content_block_delta
  data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" Done."}}

  event: content_block_stop
  data: {"type":"content_block_stop","index":0}

  event: content_block_start
  data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

  event: content_block_delta
  data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Answer."}}

  event: content_block_stop
  data: {"type":"content_block_stop","index":1}

  event: message_delta
  data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":20}}

  event: message_stop
  data: {"type":"message_stop"}
  """

  test "thinking_delta events are accumulated into a thinking block" do
    state = run([@thinking_stream])
    # The thinking block is at index 0
    thinking_block = Map.get(state.blocks, 0)
    assert thinking_block.type == "thinking"
    assert thinking_block.thinking == "Let me analyze... Done."
  end

  test "thinking block does NOT appear in text delta stream (not sent as answer text)" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    run([@thinking_stream], fn text -> Agent.update(agent, &[text | &1]) end)
    tokens = Agent.get(agent, & &1) |> Enum.reverse()
    # Only "Answer." should be streamed, not the thinking text
    combined = Enum.join(tokens)
    assert combined == "Answer."
    refute combined =~ "Let me analyze"
  end

  # ── two parallel tool_use blocks (spec §6.4) ─────────────────────────────

  @two_tools_stream """
  event: message_start
  data: {"type":"message_start","message":{"id":"msg_2t","usage":{"input_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}}

  event: content_block_start
  data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_A","name":"get_schedule","input":{}}}

  event: content_block_delta
  data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"date\\":\\"2026-07-02\\"}"}}

  event: content_block_stop
  data: {"type":"content_block_stop","index":0}

  event: content_block_start
  data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_B","name":"get_boxscore","input":{}}}

  event: content_block_delta
  data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"game_pk\\":700001}"}}

  event: content_block_stop
  data: {"type":"content_block_stop","index":1}

  event: message_delta
  data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":55}}

  event: message_stop
  data: {"type":"message_stop"}
  """

  test "two parallel tool_use blocks are both decoded from a single stream" do
    result = run([@two_tools_stream]) |> then(&finalize/1)

    assert result.stop_reason == "tool_use"
    assert length(result.content) == 2

    schedule_block = Enum.find(result.content, &(&1["name"] == "get_schedule"))
    boxscore_block = Enum.find(result.content, &(&1["name"] == "get_boxscore"))

    assert schedule_block["id"] == "toolu_A"
    assert schedule_block["input"] == %{"date" => "2026-07-02"}
    assert boxscore_block["id"] == "toolu_B"
    assert boxscore_block["input"] == %{"game_pk" => 700_001}
  end

  test "two-tool stream split across chunk boundaries is still fully decoded" do
    chunks = for <<c::binary-size(40) <- @two_tools_stream>>, do: c

    remainder =
      binary_part(
        @two_tools_stream,
        div(byte_size(@two_tools_stream), 40) * 40,
        rem(byte_size(@two_tools_stream), 40)
      )

    all_chunks = chunks ++ [remainder]
    result = run(all_chunks) |> then(&finalize/1)

    assert Enum.find(result.content, &(&1["name"] == "get_schedule"))["input"] == %{
             "date" => "2026-07-02"
           }

    assert Enum.find(result.content, &(&1["name"] == "get_boxscore"))["input"] == %{
             "game_pk" => 700_001
           }
  end

  # ── input_json_delta fragmented across many tiny chunks ──────────────────

  test "input_json_delta assembled from very small chunks decodes correctly" do
    stream = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_frag","usage":{"input_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_frag","name":"get_homers_by_date","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"da"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"te\\":\\"20"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"26-07-02\\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":8}}

    event: message_stop
    data: {"type":"message_stop"}
    """

    result = run([stream]) |> then(&finalize/1)
    tool_block = Enum.find(result.content, &(&1["name"] == "get_homers_by_date"))
    assert tool_block["input"] == %{"date" => "2026-07-02"}
  end

  # Reuse the finalize logic by round-tripping through the same shaping the
  # client applies. We call the private-equivalent via apply + a tiny shim.
  defp finalize(state) do
    content =
      state.order
      |> Enum.map(&Map.get(state.blocks, &1))
      |> Enum.map(fn
        %{type: "text", text: t} ->
          %{"type" => "text", "text" => t}

        %{type: "tool_use", id: id, name: n, input_json: j} ->
          %{"type" => "tool_use", "id" => id, "name" => n, "input" => Jason.decode!(j)}

        other ->
          other
      end)

    %{
      message_id: state.message_id,
      content: content,
      usage: state.usage,
      stop_reason: state.stop_reason
    }
  end
end
