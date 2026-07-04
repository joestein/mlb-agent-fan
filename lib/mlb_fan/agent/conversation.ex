defmodule MlbFan.Agent.Conversation do
  @moduledoc """
  One GenServer per chat session. Holds the Anthropic message history (so the
  follow-up question can reference the prior answer) and runs the tool-use loop
  in a background task, streaming text deltas to the LiveView over PubSub on the
  topic `"chat:<session_id>"`.

  Broadcast messages:
    * `{:assistant_started, message_id, question_label}`
    * `{:delta, message_id, token}`
    * `{:assistant_done, message_id, text, %{cost_usd:, input:, output:}}`
  """
  use GenServer

  alias MlbFan.Agent.{AnswerCache, Loop}
  alias MlbFan.Llm.CostTracker
  alias MlbFan.Research.ApiUsage

  @registry MlbFan.ChatRegistry

  # ── client API ────────────────────────────────────────────────────────────

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  @doc "Ensure a conversation process exists for the session (under the DynamicSupervisor)."
  def ensure_started(session_id) do
    case DynamicSupervisor.start_child(MlbFan.ConversationSupervisor, {__MODULE__, session_id}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @doc """
  Ask a question. `opts`: `:question_label`, `:cache_key`
  (`{question_key, for_date}` for the free daily-answer cache).
  """
  def ask(session_id, text, opts \\ []) do
    GenServer.cast(via(session_id), {:ask, text, opts})
  end

  def topic(session_id), do: "chat:#{session_id}"

  # ── server ────────────────────────────────────────────────────────────────

  @impl true
  def init(session_id), do: {:ok, %{session_id: session_id, messages: []}}

  @impl true
  def handle_cast({:ask, text, opts}, state) do
    label = Keyword.get(opts, :question_label, "freeform")
    cache_key = Keyword.get(opts, :cache_key)
    message_id = gen_message_id()
    sid = state.session_id

    broadcast(sid, {:assistant_started, message_id, label})

    case cache_key && AnswerCache.get(cache_key) do
      %{rendered_markdown: md} ->
        # Free same-day cache hit — no LLM call.
        broadcast(
          sid,
          {:assistant_done, message_id, md,
           %{cost_usd: Decimal.new(0), input: 0, output: 0, cached: true}}
        )

        {:noreply, state}

      _ ->
        if cap_reached?(sid) do
          # Soft per-session spend cap (spec §13): refuse further paid LLM turns.
          broadcast(
            sid,
            {:assistant_done, message_id, cap_message(),
             %{cost_usd: Decimal.new(0), input: 0, output: 0, cached: false}}
          )

          {:noreply, state}
        else
          run_turn(text, label, message_id, cache_key, state)
        end
    end
  end

  @impl true
  def handle_info({:turn_done, messages}, state) do
    {:noreply, %{state | messages: messages}}
  end

  defp run_turn(text, label, message_id, cache_key, state) do
    sid = state.session_id
    messages = state.messages ++ [%{"role" => "user", "content" => text}]
    parent = self()

    Task.start(fn ->
      on_delta = fn token -> broadcast(sid, {:delta, message_id, token}) end

      result =
        case Loop.run(messages,
               session_id: sid,
               question_label: label,
               on_delta: on_delta,
               message_id: message_id
             ) do
          {:ok, r} ->
            r

          {:error, reason} ->
            %{
              text: error_text(reason),
              messages: messages,
              message_id: message_id
            }
        end

      send(parent, {:turn_done, result.messages})
      maybe_cache(cache_key, result, message_id)
      cost = CostTracker.message_total(message_id)
      tokens = CostTracker.message_tokens(message_id)

      broadcast(
        sid,
        {:assistant_done, message_id, result.text,
         %{
           cost_usd: cost,
           input: tokens.input,
           output: tokens.output,
           cached: false,
           # Cumulative external-API (Exa) spend for the session so the UI badge
           # reflects real cost, not LLM-only (spec §10 — Exa is ~half of Q2).
           api_session_usd: ApiUsage.session_total(sid)
         }}
      )
    end)

    {:noreply, %{state | messages: messages}}
  end

  defp maybe_cache(nil, _result, _mid), do: :ok

  defp maybe_cache({question_key, for_date}, result, message_id) do
    AnswerCache.put(question_key, for_date, result.text, CostTracker.message_total(message_id))
  end

  # ── spend cap ───────────────────────────────────────────────────────────

  # A session is capped once its combined LLM + external-API spend reaches the
  # configured ceiling (>=, so a cap of 0 blocks immediately).
  defp cap_reached?(session_id) do
    spent = Decimal.add(CostTracker.session_total(session_id), ApiUsage.session_total(session_id))
    Decimal.compare(spent, spend_cap()) != :lt
  end

  defp spend_cap do
    Application.get_env(:mlb_fan, :session_spend_cap_usd, "5.00")
    |> to_string()
    |> Decimal.new()
  end

  defp cap_message do
    cap = spend_cap()

    "This session has reached its spending cap of $#{cap}. No further AI calls will be made " <>
      "for this session. To continue, raise SESSION_SPEND_CAP_USD (or the " <>
      ":session_spend_cap_usd config) and start a new session."
  end

  # Turn an internal error reason into a user-facing message. The Anthropic
  # client surfaces the real API message (e.g. a billing/credits or rate-limit
  # notice, which Anthropic returns as HTTP 400) so the user sees the actual
  # cause instead of an opaque error tuple.
  defp error_text({:api_error, status, message}) when is_binary(message) and message != "" do
    "Sorry — the Anthropic API rejected this request (HTTP #{status}): #{message}"
  end

  defp error_text(:no_api_key) do
    "No Anthropic API key is configured. Set ANTHROPIC_API_KEY in your environment and restart."
  end

  defp error_text(reason) do
    "Sorry — I couldn't complete that request (#{inspect(reason)})."
  end

  defp broadcast(session_id, message) do
    Phoenix.PubSub.broadcast(MlbFan.PubSub, topic(session_id), message)
  end

  defp gen_message_id,
    do: "msg_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))

  defp via(session_id), do: {:via, Registry, {@registry, session_id}}
end
