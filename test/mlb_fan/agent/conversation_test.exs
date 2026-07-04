defmodule MlbFan.Agent.ConversationTest do
  use MlbFan.DataCase, async: false

  @moduletag :db

  alias MlbFan.Agent.{AnswerCache, Conversation}
  alias MlbFan.Llm.Schemas.LlmUsage

  setup do
    prev = Application.get_env(:mlb_fan, :session_spend_cap_usd)
    on_exit(fn -> Application.put_env(:mlb_fan, :session_spend_cap_usd, prev) end)
    :ok
  end

  test "a session at or over its spend cap refuses further LLM turns (no Anthropic call)" do
    # A $0 cap makes any session immediately capped (compare/2 is :eq, not :lt).
    Application.put_env(:mlb_fan, :session_spend_cap_usd, "0.00")

    sid = "cap_sess_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(MlbFan.PubSub, Conversation.topic(sid))
    Conversation.ensure_started(sid)

    Conversation.ask(sid, "who homered yesterday?")

    assert_receive {:assistant_started, mid, _label}, 1_000
    assert_receive {:assistant_done, ^mid, text, meta}, 1_000

    assert text =~ "spending cap"
    assert text =~ "SESSION_SPEND_CAP_USD"
    assert Decimal.equal?(meta.cost_usd, Decimal.new(0))

    # The LLM was never called: no llm_usage rows for this session.
    assert Repo.aggregate(from(u in LlmUsage, where: u.session_id == ^sid), :count) == 0
  end

  test "a fresh session below the cap proceeds to a real turn (not short-circuited)" do
    Application.put_env(:mlb_fan, :session_spend_cap_usd, "5.00")
    Application.put_env(:mlb_fan, :anthropic_api_key, "test-key")
    on_exit(fn -> Application.delete_env(:mlb_fan, :anthropic_api_key) end)

    # Shared mode so the conversation's background Task reaches this stub.
    Req.Test.set_req_test_to_shared(%{})

    Req.Test.stub(MlbFan.ReqStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, end_turn_sse())
    end)

    sid = "ok_sess_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(MlbFan.PubSub, Conversation.topic(sid))
    Conversation.ensure_started(sid)

    Conversation.ask(sid, "hello")

    assert_receive {:assistant_started, mid, _label}, 1_000
    assert_receive {:assistant_done, ^mid, text, _meta}, 2_000

    refute text =~ "spending cap"
    assert text =~ "Hello there"
  end

  test "a failed turn (API error) is not cached and surfaces the real message" do
    Application.put_env(:mlb_fan, :session_spend_cap_usd, "5.00")
    Application.put_env(:mlb_fan, :anthropic_api_key, "test-key")
    on_exit(fn -> Application.delete_env(:mlb_fan, :anthropic_api_key) end)

    Req.Test.set_req_test_to_shared(%{})

    # Anthropic returns a billing problem as HTTP 400 with a JSON error body.
    Req.Test.stub(MlbFan.ReqStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        400,
        ~s({"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API."},"request_id":"req_test"})
      )
    end)

    cache_key = {"hrs_yesterday", ~D[2026-07-03]}

    sid = "err_sess_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(MlbFan.PubSub, Conversation.topic(sid))
    Conversation.ensure_started(sid)

    Conversation.ask(sid, "who homered yesterday?",
      question_label: "hrs_yesterday",
      cache_key: cache_key
    )

    assert_receive {:assistant_started, mid, _label}, 1_000
    assert_receive {:assistant_done, ^mid, text, _meta}, 2_000

    # The real API message is surfaced, not an opaque {:api_error, 400}.
    assert text =~ "credit balance is too low"
    assert text =~ "400"

    # Crucially: a failed turn is NOT written to the answer cache, so a later
    # click retries instead of serving the error for free.
    assert AnswerCache.get(cache_key) == nil
  end

  defp end_turn_sse do
    """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_ok","usage":{"input_tokens":10,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello there."}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

    event: message_stop
    data: {"type":"message_stop"}

    """
  end
end
