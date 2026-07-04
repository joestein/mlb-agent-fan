defmodule MlbFan.HttpTest do
  use ExUnit.Case, async: false

  alias MlbFan.Http

  # ── allowlist predicate ───────────────────────────────────────────────────

  test "the three sanctioned hosts are allowed" do
    assert Http.allowed_host?("https://statsapi.mlb.com/api/v1/schedule")
    assert Http.allowed_host?("https://api.anthropic.com/v1/messages")
    assert Http.allowed_host?("https://api.exa.ai/search")
    # case-insensitive
    assert Http.allowed_host?("https://STATSAPI.MLB.COM/x")
  end

  test "any other host is rejected" do
    refute Http.allowed_host?("https://evil.example.com/x")
    refute Http.allowed_host?("http://localhost:4000/mcp")
    refute Http.allowed_host?("not-a-url")
    refute Http.allowed_host?(nil)
  end

  # ── opts/1 egress enforcement (no test plug ⇒ real request path) ───────────

  describe "opts/1 with the test plug removed (production egress path)" do
    setup do
      prev = Application.get_env(:mlb_fan, :req_plug)
      Application.delete_env(:mlb_fan, :req_plug)
      on_exit(fn -> Application.put_env(:mlb_fan, :req_plug, prev) end)
      :ok
    end

    test "a request to a disallowed host raises" do
      assert_raise ArgumentError, ~r/egress allowlist/, fn ->
        Http.opts(url: "https://evil.example.com/steal")
      end
    end

    test "a request to a sanctioned host passes through with its options intact" do
      opts = Http.opts(url: "https://statsapi.mlb.com/api/v1/schedule", receive_timeout: 5_000)
      assert Keyword.get(opts, :url) == "https://statsapi.mlb.com/api/v1/schedule"
      assert Keyword.get(opts, :receive_timeout) == 5_000
      refute Keyword.has_key?(opts, :plug)
    end
  end

  test "with the test plug configured, the allowlist is bypassed and the plug is injected" do
    # Default test config sets :req_plug, so any host is routed to the stub.
    opts = Http.opts(url: "https://anything.example.com/x")
    assert Keyword.get(opts, :plug) == {Req.Test, MlbFan.ReqStub}
  end
end
