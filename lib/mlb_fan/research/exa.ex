defmodule MlbFan.Research.Exa do
  @moduledoc """
  Direct HTTP client for the Exa.ai search API (patterns mined from
  sports-fanatic: retry/backoff, key-from-config, http/https URL safety). Only
  `http`/`https` result URLs are kept, blocking `javascript:`/`data:` URIs from
  ever reaching the UI as links (spec §13).
  """

  require Logger

  alias MlbFan.Http

  @base_url "https://api.exa.ai"
  @timeout 15_000
  @max_retries 3
  @retry_base_ms 500

  @doc """
  Search Exa. Options: `:num_results` (default 5, capped 10), `:days_back`
  (default 7). Returns `{:ok, results}` (possibly empty) or `{:error, reason}`.
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query) do
    case api_key() do
      key when is_binary(key) and key != "" ->
        num_results = opts |> Keyword.get(:num_results, 5) |> min(10)
        days_back = Keyword.get(opts, :days_back, 7)

        start_date =
          Date.utc_today()
          |> Date.add(-days_back)
          |> Date.to_iso8601()
          |> Kernel.<>("T00:00:00.000Z")

        body = %{
          query: query,
          numResults: num_results,
          startPublishedDate: start_date,
          type: search_type(),
          contents: %{text: %{maxCharacters: 2000}}
        }

        do_search(body, key, 1)

      _ ->
        Logger.warning("Exa API key not configured; skipping search")
        {:ok, []}
    end
  end

  @doc """
  True when an Exa API key is configured. Callers use this to avoid counting a
  no-key `{:ok, []}` (which performs no network request) as billable usage.
  """
  @spec configured?() :: boolean()
  def configured? do
    case api_key() do
      key when is_binary(key) and key != "" -> true
      _ -> false
    end
  end

  defp do_search(body, key, attempt) do
    opts =
      Http.opts(
        url: "#{@base_url}/search",
        json: body,
        headers: [{"x-api-key", key}, {"content-type", "application/json"}],
        receive_timeout: @timeout
      )

    case Req.post(opts) do
      {:ok, %Req.Response{status: 200, body: %{"results" => results}}} when is_list(results) ->
        {:ok, parse_results(results)}

      {:ok, %Req.Response{status: 200}} ->
        {:ok, []}

      {:ok, %Req.Response{status: _status}} when attempt < @max_retries ->
        Process.sleep(@retry_base_ms * attempt)
        do_search(body, key, attempt + 1)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:api_error, status}}

      {:error, _reason} when attempt < @max_retries ->
        Process.sleep(@retry_base_ms * attempt)
        do_search(body, key, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_results(results) do
    results
    |> Enum.map(fn r ->
      %{
        title: r["title"] || "",
        url: r["url"] || "",
        text: r["text"] || "",
        published_date: r["publishedDate"]
      }
    end)
    |> Enum.filter(&valid_url?(&1.url))
  end

  @doc "Cap results to `max_per_domain` per host, preserving rank order."
  @spec dedup_by_domain([map()], pos_integer()) :: [map()]
  def dedup_by_domain(results, max_per_domain \\ 2) do
    {kept, _counts} =
      Enum.reduce(results, {[], %{}}, fn result, {acc, counts} ->
        host = host_of(result)
        current = Map.get(counts, host, 0)

        if current < max_per_domain do
          {[result | acc], Map.put(counts, host, current + 1)}
        else
          {acc, counts}
        end
      end)

    Enum.reverse(kept)
  end

  defp host_of(%{url: url}) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: h} when is_binary(h) and h != "" -> String.downcase(h)
      _ -> ""
    end
  end

  defp host_of(_), do: ""

  # Only http/https — blocks javascript:/data: URI injection.
  defp valid_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> true
      _ -> false
    end
  end

  defp valid_url?(_), do: false

  defp api_key, do: Application.get_env(:mlb_fan, :exa, [])[:api_key]
  defp search_type, do: Application.get_env(:mlb_fan, :exa, [])[:type] || "auto"
end
