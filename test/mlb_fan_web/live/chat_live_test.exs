defmodule MlbFanWeb.ChatLiveTest do
  use MlbFanWeb.ConnCase, async: false

  @moduletag :db

  import Phoenix.LiveViewTest

  test "mount shows the welcome message and an autofocused input", %{conn: conn} do
    {:ok, _live, html} = live(conn, "/")

    assert html =~ "Welcome to MLB Fan Agent"
    assert html =~ "autofocus"
  end

  test "default question #1 button is present; #2 is hidden until #1 is answered", %{conn: conn} do
    {:ok, live, _html} = live(conn, "/")

    assert has_element?(live, "button", "Who homered yesterday")
    refute has_element?(live, "button", "Who's pitching against them today")
  end

  test "the per-session cost badge renders", %{conn: conn} do
    {:ok, _live, html} = live(conn, "/")
    assert html =~ "Session: $"
  end

  # ── streaming delta append (spec §7 / §12) ───────────────────────────────

  test "streamed deltas are appended to the assistant message in the DOM", %{conn: conn} do
    {:ok, live, _html} = live(conn, "/")
    msg_id = "test_delta_msg"

    # Step 1: mark the beginning of an assistant message
    send(live.pid, {:assistant_started, msg_id, "hrs_yesterday"})
    # Step 2: stream some deltas
    send(live.pid, {:delta, msg_id, "Judge "})
    send(live.pid, {:delta, msg_id, "homered!"})

    html = render(live)
    assert html =~ "Judge homered!"
  end

  test "assistant_done finalizes the message and flips answered_q1 for hrs_yesterday label",
       %{conn: conn} do
    {:ok, live, _html} = live(conn, "/")
    msg_id = "test_done_msg"

    # Before: button #2 hidden
    refute has_element?(live, "button", "Who's pitching against them today")

    # Simulate a full assistant turn completing for Q1
    send(live.pid, {:assistant_started, msg_id, "hrs_yesterday"})
    send(live.pid, {:delta, msg_id, "Results here."})

    send(
      live.pid,
      {:assistant_done, msg_id, "Results here.",
       [cost_usd: Decimal.new("0.09"), input: 10_000, output: 1200, cached: false]}
    )

    html = render(live)
    # After: button #2 should appear (answered_q1 = true)
    assert has_element?(live, "button", "Who's pitching against them today")
    # Cost badge should show the cost
    assert html =~ "$0.09"
  end

  test "per-message cost badge renders with token counts after assistant_done", %{conn: conn} do
    {:ok, live, _html} = live(conn, "/")
    msg_id = "test_cost_msg"

    send(live.pid, {:assistant_started, msg_id, "freeform"})

    send(
      live.pid,
      {:assistant_done, msg_id, "Some answer.",
       [cost_usd: Decimal.new("0.34"), input: 53_000, output: 3_000, cached: false]}
    )

    html = render(live)
    assert html =~ "$0.34"
    # Token counts should also be visible (53.0K in)
    assert html =~ "53.0K"
    assert html =~ "3.0K"
  end

  test "per-session badge includes Exa (api_session_usd) spend, not just LLM cost", %{conn: conn} do
    {:ok, live, _html} = live(conn, "/")
    msg_id = "test_exa_cost"

    send(live.pid, {:assistant_started, msg_id, "matchup_odds"})

    # LLM message cost $0.10 + cumulative Exa session spend $0.36 = $0.46 badge.
    send(
      live.pid,
      {:assistant_done, msg_id, "Assessment.",
       [
         cost_usd: Decimal.new("0.10"),
         input: 1000,
         output: 100,
         cached: false,
         api_session_usd: Decimal.new("0.36")
       ]}
    )

    html = render(live)
    # Session badge reflects combined spend (spec §10 — Exa is ~half of Q2).
    assert html =~ "Session: $0.46"
  end

  test "freeform question does NOT flip answered_q1", %{conn: conn} do
    {:ok, live, _html} = live(conn, "/")
    msg_id = "test_freeform"

    send(live.pid, {:assistant_started, msg_id, "freeform"})
    send(live.pid, {:assistant_done, msg_id, "Free answer.", [cost_usd: Decimal.new("0.01")]})

    # Button #2 should still be hidden for a freeform question
    refute has_element?(live, "button", "Who's pitching against them today")
  end

  # ── server-side concurrency guard (spec §13) ─────────────────────────────

  test "a second submit is ignored while a turn is in flight", %{conn: conn} do
    Application.put_env(:mlb_fan, :anthropic_api_key, "test-key")
    on_exit(fn -> Application.delete_env(:mlb_fan, :anthropic_api_key) end)

    # Shared Req.Test mode so the conversation's background Task uses our stub.
    Req.Test.set_req_test_to_shared(%{})
    parent = self()

    Req.Test.stub(MlbFan.ReqStub, fn conn ->
      send(parent, :anthropic_called)
      # Hang the turn so `busy` stays true deterministically for the assertions.
      Process.sleep(:infinity)
      conn
    end)

    {:ok, live, _html} = live(conn, "/")

    # First turn starts (busy=true) and hangs inside the Anthropic stub.
    live |> form("form", %{"message" => "first question"}) |> render_submit()
    assert_receive :anthropic_called, 1_500

    # Second submit while busy must be ignored: no new bubble, no 2nd call.
    live |> form("form", %{"message" => "second question"}) |> render_submit()

    html = render(live)
    assert html =~ "first question"
    refute html =~ "second question"
    refute_receive :anthropic_called, 300
  end

  # ── Markdown sanitization in the chat (spec §13) ─────────────────────────

  test "assistant message with script tags has them stripped before rendering", %{conn: conn} do
    {:ok, live, _html} = live(conn, "/")
    msg_id = "xss_msg"

    send(live.pid, {:assistant_started, msg_id, "freeform"})

    # Put regular text BEFORE the script injection so Earmark treats the
    # paragraph as regular text + inline HTML (not a raw HTML block).
    send(
      live.pid,
      {:assistant_done, msg_id, "Judge hit a HR! <script>alert(1)</script>",
       [cost_usd: Decimal.new("0.01"), input: 100, output: 10, cached: false]}
    )

    html = render(live)
    refute html =~ "<script>"
    assert html =~ "Judge hit a HR"
  end
end
