defmodule MlbFan.Llm.Sse do
  @moduledoc """
  Incremental Server-Sent-Events parser for Anthropic's streaming Messages API.

  `feed/2` accepts arbitrary byte chunks (which may split an event across TCP
  boundaries) and returns the list of complete events parsed so far plus the
  carried-over parser state. Each event is `%{event: name, data: decoded_json}`.
  Comment/`ping` lines are ignored.
  """

  @type state :: %{buffer: String.t(), event: String.t() | nil, data: [String.t()]}
  @type event :: %{event: String.t() | nil, data: map()}

  @spec new() :: state()
  def new, do: %{buffer: "", event: nil, data: []}

  @doc "Feed a chunk; returns `{events, new_state}`."
  @spec feed(state(), binary()) :: {[event()], state()}
  def feed(%{buffer: buffer} = state, chunk) do
    {lines, rest} = split_lines(buffer <> chunk)

    {events, state} =
      Enum.reduce(lines, {[], %{state | buffer: ""}}, fn line, {evs, s} ->
        handle_line(line, evs, s)
      end)

    {Enum.reverse(events), %{state | buffer: rest}}
  end

  # All buffered complete lines, plus the trailing (possibly partial) remainder.
  defp split_lines(str) do
    parts = String.split(str, "\n")
    {rest, complete} = List.pop_at(parts, -1)
    {complete, rest}
  end

  defp handle_line(line, evs, state) do
    line = String.trim_trailing(line, "\r")

    cond do
      line == "" ->
        dispatch(evs, state)

      String.starts_with?(line, ":") ->
        {evs, state}

      String.starts_with?(line, "event:") ->
        {evs, %{state | event: field(line, "event:")}}

      String.starts_with?(line, "data:") ->
        {evs, %{state | data: [field(line, "data:") | state.data]}}

      true ->
        {evs, state}
    end
  end

  defp dispatch(evs, %{event: nil, data: []} = state), do: {evs, state}

  defp dispatch(evs, state) do
    payload = state.data |> Enum.reverse() |> Enum.join("\n")

    event =
      case decode(payload) do
        {:ok, data} -> %{event: state.event, data: data}
        :error -> %{event: state.event, data: %{"raw" => payload}}
      end

    {[event | evs], %{state | event: nil, data: []}}
  end

  defp field(line, prefix) do
    line |> String.replace_prefix(prefix, "") |> String.trim_leading()
  end

  defp decode(""), do: :error

  defp decode(payload) do
    case Jason.decode(payload) do
      {:ok, data} -> {:ok, data}
      _ -> :error
    end
  end
end
