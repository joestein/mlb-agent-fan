defmodule MlbFanWeb.ChatLive do
  @moduledoc """
  The MLB Fan Agent chat (spec §7). Mounts with the welcome message, an
  autofocused input, and two default-question buttons — button #2 is hidden
  until question #1 has been answered. Streams Claude's tokens over PubSub and
  shows per-message + per-session cost.
  """
  use MlbFanWeb, :live_view

  import MlbFanWeb.Components.CostReadout

  alias MlbFan.Agent.{Conversation, Prompts}
  alias MlbFan.Cost.Projection
  alias MlbFan.Stats
  alias MlbFanWeb.Markdown

  @welcome "Welcome to MLB Fan Agent"

  @impl true
  def mount(_params, _session, socket) do
    session_id = "sess_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))

    if connected?(socket) do
      Phoenix.PubSub.subscribe(MlbFan.PubSub, Conversation.topic(session_id))
      Conversation.ensure_started(session_id)
    end

    socket =
      socket
      |> assign(:session_id, session_id)
      |> assign(:welcome, @welcome)
      |> assign(:messages, [
        %{
          id: "welcome",
          role: :assistant,
          text: @welcome,
          done?: true,
          cost: nil,
          input: 0,
          output: 0,
          cached: false
        }
      ])
      |> assign(:answered_q1, false)
      |> assign(:busy, false)
      |> assign(:session_cost, Decimal.new(0))
      |> assign(:api_session_cost, Decimal.new(0))
      |> assign(:projection, Projection.project())
      |> assign(:pending_labels, %{})
      |> assign(:button1_label, Prompts.button1_label())
      |> assign(:button2_label, Prompts.button2_label())

    {:ok, socket}
  end

  @impl true
  def handle_event("default_1", _params, %{assigns: %{busy: true}} = socket),
    do: {:noreply, socket}

  def handle_event("default_1", _params, socket) do
    text = Prompts.question1(Stats.today())
    cache_key = {"hrs_yesterday", Stats.yesterday()}
    {:noreply, ask(socket, text, "hrs_yesterday", cache_key)}
  end

  def handle_event("default_2", _params, %{assigns: %{busy: true}} = socket),
    do: {:noreply, socket}

  def handle_event("default_2", _params, socket) do
    if socket.assigns.answered_q1 do
      text = Prompts.question2(Stats.today())
      cache_key = {"matchup_odds", Stats.today()}
      {:noreply, ask(socket, text, "matchup_odds", cache_key)}
    else
      {:noreply, socket}
    end
  end

  # Server-side concurrency guard: ignore new turns while one is in flight so a
  # double-click or a crafted client cannot spawn concurrent (expensive) loops.
  def handle_event("submit", _params, %{assigns: %{busy: true}} = socket),
    do: {:noreply, socket}

  def handle_event("submit", %{"message" => text}, socket) do
    text = String.trim(text || "")
    if text == "", do: {:noreply, socket}, else: {:noreply, ask(socket, text, "freeform", nil)}
  end

  defp ask(socket, text, label, cache_key) do
    Conversation.ask(socket.assigns.session_id, text, question_label: label, cache_key: cache_key)

    socket
    |> update(
      :messages,
      &(&1 ++
          [
            %{
              id: "u_#{System.unique_integer([:positive])}",
              role: :user,
              text: text,
              done?: true,
              cost: nil,
              input: 0,
              output: 0,
              cached: false
            }
          ])
    )
    |> assign(:busy, true)
  end

  # ── streaming updates ───────────────────────────────────────────────────

  @impl true
  def handle_info({:assistant_started, message_id, label}, socket) do
    msg = %{
      id: message_id,
      role: :assistant,
      text: "",
      done?: false,
      cost: nil,
      input: 0,
      output: 0,
      cached: false
    }

    {:noreply,
     socket
     |> update(:messages, &(&1 ++ [msg]))
     |> update(:pending_labels, &Map.put(&1, message_id, label))}
  end

  def handle_info({:delta, message_id, token}, socket) do
    {:noreply, update(socket, :messages, &append_token(&1, message_id, token))}
  end

  def handle_info({:assistant_done, message_id, text, meta}, socket) do
    label = Map.get(socket.assigns.pending_labels, message_id)
    answered_q1 = socket.assigns.answered_q1 or label == "hrs_yesterday"
    # LLM cost accumulates per message; Exa spend arrives as a cumulative
    # session snapshot, so it replaces (not adds to) the prior snapshot.
    session_cost = Decimal.add(socket.assigns.session_cost, to_decimal(meta[:cost_usd]))
    api_session_cost = to_decimal(meta[:api_session_usd])

    {:noreply,
     socket
     |> update(:messages, &finalize_message(&1, message_id, text, meta))
     |> assign(:answered_q1, answered_q1)
     |> assign(:busy, false)
     |> assign(:session_cost, session_cost)
     |> assign(:api_session_cost, api_session_cost)
     |> assign(:projection, Projection.project())}
  end

  defp append_token(messages, id, token) do
    Enum.map(messages, fn
      %{id: ^id} = m -> %{m | text: m.text <> token}
      m -> m
    end)
  end

  defp finalize_message(messages, id, text, meta) do
    Enum.map(messages, fn
      %{id: ^id} = m ->
        %{
          m
          | text: text,
            done?: true,
            cost: meta[:cost_usd],
            input: meta[:input] || 0,
            output: meta[:output] || 0,
            cached: meta[:cached] || false
        }

      m ->
        m
    end)
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(_), do: Decimal.new(0)

  # ── render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto flex h-screen max-w-3xl flex-col p-4">
      <header class="mb-3 flex items-center justify-between border-b pb-2">
        <h1 class="text-lg font-semibold">⚾ MLB Fan Agent</h1>
        <.session_badge cost={Decimal.add(@session_cost, @api_session_cost)} />
      </header>

      <div id="messages" class="flex-1 space-y-4 overflow-y-auto" phx-update="replace">
        <div :for={msg <- @messages} id={msg.id} class={message_class(msg)}>
          <div
            :if={msg.role == :assistant and msg.done? and msg.id != "welcome"}
            class="prose prose-sm max-w-none"
          >
            {Markdown.to_safe_html(msg.text)}
          </div>
          <div
            :if={msg.role == :assistant and not msg.done?}
            class="whitespace-pre-wrap text-zinc-700"
          >
            {msg.text}<span class="animate-pulse">▍</span>
          </div>
          <div
            :if={msg.role == :assistant and msg.done? and msg.id == "welcome"}
            class="text-zinc-800"
          >
            {msg.text}
          </div>
          <div :if={msg.role == :user} class="whitespace-pre-wrap">{msg.text}</div>
          <div :if={msg.role == :assistant and msg.done? and not is_nil(msg.cost)} class="mt-1">
            <.message_badge cost={msg.cost} input={msg.input} output={msg.output} cached={msg.cached} />
          </div>
        </div>
      </div>

      <div class="mt-3 space-y-2">
        <div class="flex flex-wrap gap-2">
          <button
            phx-click="default_1"
            disabled={@busy}
            class="rounded-full bg-blue-600 px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
          >
            {@button1_label}
          </button>
          <button
            :if={@answered_q1}
            phx-click="default_2"
            disabled={@busy}
            class="rounded-full bg-emerald-600 px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
          >
            {@button2_label}
          </button>
        </div>

        <form phx-submit="submit" class="flex gap-2">
          <input
            type="text"
            name="message"
            autofocus
            autocomplete="off"
            placeholder="Ask about home runs, streaks, and matchups…"
            class="flex-1 rounded-lg border px-3 py-2"
          />
          <button
            type="submit"
            disabled={@busy}
            class="rounded-lg bg-zinc-900 px-4 py-2 text-white disabled:opacity-50"
          >
            Send
          </button>
        </form>

        <.projection projection={@projection} />
      </div>
    </div>
    """
  end

  defp message_class(%{role: :user}), do: "rounded-lg bg-zinc-100 p-3 text-sm ml-auto max-w-[80%]"
  defp message_class(_), do: "rounded-lg bg-white p-3 text-sm"
end
