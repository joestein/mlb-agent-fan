defmodule MlbFan.Llm.Anthropic do
  @moduledoc """
  Raw-HTTP (Req) streaming client for the Anthropic Messages API, model
  `claude-opus-4-8` (spec §6).

  Hard constraints (a 400 on opus-4-8 if violated), enforced by `build_body/4`
  and guarded by a unit test:

    * `"stream": true` always
    * `"thinking": {"type": "adaptive"}` (never `budget_tokens`)
    * NEVER `temperature` / `top_p` / `top_k`
    * final system block carries `cache_control: {type: ephemeral}` so the
      system prompt + tool definitions cache together.
  """

  require Logger

  alias MlbFan.Http
  alias MlbFan.Llm.Sse

  @base_url "https://api.anthropic.com/v1/messages"
  @version "2023-06-01"
  @max_tokens 4096
  @timeout 120_000

  @doc """
  Build the outbound request body. `system` is the frozen system prompt text;
  the single system block carries `cache_control`. Forbidden sampling params are
  never added.
  """
  @spec build_body(String.t(), [map()], [map()], keyword()) :: map()
  def build_body(system, tools, messages, opts \\ []) do
    model = Keyword.get(opts, :model, default_model())

    %{
      "model" => model,
      "max_tokens" => Keyword.get(opts, :max_tokens, @max_tokens),
      "stream" => true,
      "thinking" => %{"type" => "adaptive"},
      "system" => [
        %{"type" => "text", "text" => system, "cache_control" => %{"type" => "ephemeral"}}
      ],
      "tools" => tools,
      "messages" => messages
    }
  end

  @doc "Configured default model (`claude-opus-4-8` unless overridden)."
  @spec default_model() :: String.t()
  def default_model, do: Application.get_env(:mlb_fan, :anthropic_model, "claude-opus-4-8")

  @doc """
  Stream a request. `on_delta` is called with each text token as it arrives.
  Returns `{:ok, result}` where result has `:message_id`, `:content` (assembled
  assistant content blocks incl. thinking + tool_use with decoded input),
  `:usage`, and `:stop_reason`. Returns `{:error, reason}` on transport/auth
  failure.
  """
  @spec stream(map(), (String.t() -> any()), keyword()) :: {:ok, map()} | {:error, term()}
  def stream(body, on_delta \\ fn _ -> :ok end, _opts \\ []) do
    case api_key() do
      key when is_binary(key) and key != "" -> do_stream(body, key, on_delta)
      _ -> {:error, :no_api_key}
    end
  end

  defp do_stream(body, key, on_delta) do
    into = fn {:data, chunk}, {req, resp} ->
      st = resp.private[:mlbfan] || initial_state()

      st =
        if resp.status == 200 do
          {events, sse} = Sse.feed(st.sse, chunk)
          Enum.reduce(events, %{st | sse: sse}, fn ev, acc -> apply_event(ev, acc, on_delta) end)
        else
          # Non-200: the body is a JSON error, not an SSE stream. Buffer it raw so
          # the real Anthropic message (e.g. billing, rate limit) can be surfaced.
          %{st | error_body: st.error_body <> chunk}
        end

      {:cont, {req, %{resp | private: Map.put(resp.private, :mlbfan, st)}}}
    end

    opts =
      Http.opts(
        url: @base_url,
        json: body,
        headers: [
          {"x-api-key", key},
          {"anthropic-version", @version},
          {"content-type", "application/json"}
        ],
        receive_timeout: @timeout,
        into: into
      )

    case Req.post(opts) do
      {:ok, %Req.Response{status: 200, private: private}} ->
        {:ok, finalize(private[:mlbfan] || initial_state())}

      {:ok, %Req.Response{status: status, private: private}} ->
        st = private[:mlbfan] || initial_state()
        {message, request_id} = parse_api_error(st.error_body)

        Logger.error(
          "Anthropic API error status=#{status} request_id=#{request_id || "?"} " <>
            "message=#{inspect(message)}"
        )

        {:error, {:api_error, status, message}}

      {:error, reason} ->
        Logger.error("Anthropic request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── streaming accumulator ─────────────────────────────────────────────────

  @doc false
  def initial_state do
    %{
      sse: Sse.new(),
      message_id: nil,
      blocks: %{},
      order: [],
      usage: %{
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0
      },
      stop_reason: nil,
      error_body: ""
    }
  end

  # Extract the human-readable message + request_id from a non-200 Anthropic
  # error body (`{"error": {"message": ...}, "request_id": ...}`).
  defp parse_api_error(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}} = decoded} ->
        {message, decoded["request_id"]}

      _ ->
        {nil, nil}
    end
  end

  defp parse_api_error(_), do: {nil, nil}

  @doc false
  # Public so it can be unit-tested by replaying a fixture event stream.
  def apply_events(state, events, on_delta \\ fn _ -> :ok end) do
    Enum.reduce(events, state, fn ev, acc -> apply_event(ev, acc, on_delta) end)
  end

  defp apply_event(%{data: %{"type" => "message_start", "message" => msg}}, st, _on_delta) do
    %{st | message_id: msg["id"], usage: merge_usage(st.usage, msg["usage"])}
  end

  defp apply_event(
         %{data: %{"type" => "content_block_start", "index" => i, "content_block" => cb}},
         st,
         _on_delta
       ) do
    block = %{
      type: cb["type"],
      text: "",
      thinking: "",
      signature: "",
      data: cb["data"],
      id: cb["id"],
      name: cb["name"],
      input_json: ""
    }

    %{st | blocks: Map.put(st.blocks, i, block), order: st.order ++ [i]}
  end

  defp apply_event(
         %{data: %{"type" => "content_block_delta", "index" => i, "delta" => delta}},
         st,
         on_delta
       ) do
    block =
      Map.get(st.blocks, i, %{type: nil, text: "", thinking: "", signature: "", input_json: ""})

    block =
      case delta["type"] do
        "text_delta" ->
          on_delta.(delta["text"] || "")
          %{block | text: block.text <> (delta["text"] || "")}

        "input_json_delta" ->
          %{block | input_json: block.input_json <> (delta["partial_json"] || "")}

        "thinking_delta" ->
          %{block | thinking: block.thinking <> (delta["thinking"] || "")}

        "signature_delta" ->
          %{block | signature: block.signature <> (delta["signature"] || "")}

        _ ->
          block
      end

    %{st | blocks: Map.put(st.blocks, i, block)}
  end

  defp apply_event(%{data: %{"type" => "message_delta", "delta" => delta} = data}, st, _on_delta) do
    stop_reason = get_in(delta, ["stop_reason"]) || st.stop_reason
    %{st | stop_reason: stop_reason, usage: merge_usage(st.usage, data["usage"])}
  end

  defp apply_event(_event, st, _on_delta), do: st

  defp merge_usage(usage, nil), do: usage

  defp merge_usage(usage, incoming) do
    Enum.reduce(
      ~w(input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens),
      usage,
      fn key, acc ->
        case incoming[key] do
          nil -> acc
          v -> Map.put(acc, String.to_existing_atom(key), v)
        end
      end
    )
  end

  # ── finalize into content blocks ──────────────────────────────────────────

  defp finalize(st) do
    content =
      st.order
      |> Enum.map(&Map.get(st.blocks, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&block_to_content/1)
      |> Enum.reject(&is_nil/1)

    %{message_id: st.message_id, content: content, usage: st.usage, stop_reason: st.stop_reason}
  end

  defp block_to_content(%{type: "text", text: text}), do: %{"type" => "text", "text" => text}

  defp block_to_content(%{type: "thinking", thinking: thinking, signature: sig}) do
    %{"type" => "thinking", "thinking" => thinking, "signature" => sig}
  end

  defp block_to_content(%{type: "redacted_thinking", data: data}),
    do: %{"type" => "redacted_thinking", "data" => data}

  defp block_to_content(%{type: "tool_use", id: id, name: name, input_json: json}) do
    input =
      case Jason.decode(json) do
        {:ok, decoded} -> decoded
        _ -> %{}
      end

    %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
  end

  defp block_to_content(_), do: nil

  # ── key resolution (mirrors sports-fanatic; never logged) ─────────────────

  defp api_key do
    Application.get_env(:mlb_fan, :anthropic_api_key) || System.get_env("ANTHROPIC_API_KEY")
  end
end
