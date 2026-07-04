defmodule MlbFan.Llm.AnthropicTest do
  use ExUnit.Case, async: false

  @moduletag :req

  alias MlbFan.Llm.Anthropic

  @forbidden ~w(temperature top_p top_k budget_tokens)

  describe "build_body/4 (R4 hard constraints)" do
    setup do
      tools = [%{"name" => "get_schedule", "input_schema" => %{"type" => "object"}}]
      messages = [%{"role" => "user", "content" => "hi"}]
      %{body: Anthropic.build_body("SYSTEM", tools, messages)}
    end

    test("always streams", %{body: body}, do: assert(body["stream"] == true))

    test "uses adaptive thinking and never budget_tokens", %{body: body} do
      assert body["thinking"] == %{"type" => "adaptive"}
      refute Map.has_key?(body["thinking"], "budget_tokens")
    end

    test "final system block carries ephemeral cache_control", %{body: body} do
      assert [%{"cache_control" => %{"type" => "ephemeral"}, "text" => "SYSTEM"}] = body["system"]
    end

    test "outbound body omits temperature/top_p/top_k/budget_tokens anywhere", %{body: body} do
      for key <- @forbidden do
        refute deep_has_key?(body, key), "forbidden key #{key} present in outbound body"
      end
    end

    test "targets the opus-4-8 model by default", %{body: body} do
      assert body["model"] == "claude-opus-4-8"
    end
  end

  defp deep_has_key?(map, key) when is_map(map) do
    Map.has_key?(map, key) or Enum.any?(Map.values(map), &deep_has_key?(&1, key))
  end

  defp deep_has_key?(list, key) when is_list(list), do: Enum.any?(list, &deep_has_key?(&1, key))
  defp deep_has_key?(_other, _key), do: false

  # ── Outbound request headers (R4) ────────────────────────────────────────

  describe "stream/3 outbound headers" do
    setup do
      prev = Application.get_env(:mlb_fan, :anthropic_api_key)
      Application.put_env(:mlb_fan, :anthropic_api_key, "test-key-r4")
      on_exit(fn -> Application.put_env(:mlb_fan, :anthropic_api_key, prev) end)
      :ok
    end

    # A minimal valid SSE stream that terminates immediately.
    defp minimal_sse do
      """
      event: message_start
      data: {"type":"message_start","message":{"id":"msg_hdr","usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}

      event: message_stop
      data: {"type":"message_stop"}
      """
    end

    test "sends anthropic-version: 2023-06-01 header (R4 spec §6.2)" do
      test_pid = self()

      Req.Test.stub(MlbFan.ReqStub, fn conn ->
        send(test_pid, {:headers, Map.new(conn.req_headers)})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, minimal_sse())
      end)

      body =
        Anthropic.build_body("sys", [], [%{"role" => "user", "content" => "hi"}])

      Anthropic.stream(body)

      assert_receive {:headers, headers}, 1000
      assert headers["anthropic-version"] == "2023-06-01"
    end

    test "sends x-api-key header with the configured key (R4 spec §6.2)" do
      test_pid = self()

      Req.Test.stub(MlbFan.ReqStub, fn conn ->
        send(test_pid, {:headers, Map.new(conn.req_headers)})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, minimal_sse())
      end)

      body =
        Anthropic.build_body("sys", [], [%{"role" => "user", "content" => "hi"}])

      Anthropic.stream(body)

      assert_receive {:headers, headers}, 1000
      assert headers["x-api-key"] == "test-key-r4"
    end

    test "returns error when no API key is configured" do
      Application.put_env(:mlb_fan, :anthropic_api_key, nil)

      body = Anthropic.build_body("sys", [], [%{"role" => "user", "content" => "hi"}])
      assert {:error, :no_api_key} = Anthropic.stream(body)
    end
  end
end
