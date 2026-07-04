defmodule MlbFan.Agent.Loop do
  @moduledoc """
  The Anthropic tool-use loop (spec §6.4). Streams a request, records per-turn
  `llm_usage`, and on `stop_reason == tool_use` runs ALL tool_use blocks through
  `MlbFan.Agent.ToolRouter`, appends a SINGLE user message of tool_results, and
  loops — capped at N iterations to prevent runaway spend. All `llm_usage` rows
  for one answer share a single logical `message_id` so per-message cost sums the
  whole loop.
  """

  require Logger

  alias MlbFan.Agent.{Prompts, ToolRouter}
  alias MlbFan.Llm.{Anthropic, CostTracker}
  alias MlbFan.Mcp.Catalog

  @doc """
  Run the loop over `messages` (a list of Anthropic message maps). Options:
  `:session_id` (required for cost tracking), `:question_label`, `:on_delta`,
  `:message_id` (logical id; generated if absent). Returns
  `{:ok, %{text:, content:, messages:, message_id:, stop_reason:}}`.
  """
  @spec run([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def run(messages, opts \\ []) do
    state = %{
      session_id: Keyword.get(opts, :session_id, "anon"),
      question_label: Keyword.get(opts, :question_label, "freeform"),
      on_delta: Keyword.get(opts, :on_delta, fn _ -> :ok end),
      message_id: Keyword.get(opts, :message_id, gen_message_id()),
      model: Anthropic.default_model(),
      max_iterations: max_iterations()
    }

    loop(messages, state, 0)
  end

  defp loop(_messages, state, turn) when turn >= state.max_iterations do
    {:ok,
     %{
       text:
         Prompts.ensure_disclaimer(
           "The assistant reached the tool-call limit before finishing. Please refine the question."
         ),
       content: [],
       messages: [],
       message_id: state.message_id,
       stop_reason: "max_iterations"
     }}
  end

  defp loop(messages, state, turn) do
    body =
      Anthropic.build_body(Prompts.system(), Catalog.anthropic_tools(), messages,
        model: state.model
      )

    case Anthropic.stream(body, state.on_delta) do
      {:ok, result} ->
        record_usage(result, state, turn)
        assistant_msg = %{"role" => "assistant", "content" => result.content}
        messages = messages ++ [assistant_msg]

        case result.stop_reason do
          "tool_use" ->
            handle_tool_use(result, messages, state, turn)

          _ ->
            {:ok, finalize(result, messages, state)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_tool_use(result, messages, state, turn) do
    tool_uses = Enum.filter(result.content, &(&1["type"] == "tool_use"))
    tool_results = ToolRouter.run(tool_uses, session_id: state.session_id)
    tool_msg = %{"role" => "user", "content" => tool_results}
    loop(messages ++ [tool_msg], state, turn + 1)
  end

  defp finalize(result, messages, state) do
    text =
      result.content
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("", & &1["text"])
      |> Prompts.ensure_disclaimer()

    %{
      text: text,
      content: result.content,
      messages: messages,
      message_id: state.message_id,
      stop_reason: result.stop_reason
    }
  end

  defp record_usage(result, state, turn) do
    usage = result.usage

    CostTracker.record(%{
      session_id: state.session_id,
      message_id: state.message_id,
      question_label: state.question_label,
      model: state.model,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      cache_creation_input_tokens: usage.cache_creation_input_tokens,
      cache_read_input_tokens: usage.cache_read_input_tokens,
      stop_reason: result.stop_reason,
      turn_index: turn
    })
  end

  defp gen_message_id,
    do: "msg_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))

  defp max_iterations do
    Application.get_env(:mlb_fan, :agent, []) |> Keyword.get(:max_loop_iterations, 8)
  end
end
