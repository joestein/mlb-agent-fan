defmodule MlbFan.Stats.Api do
  @moduledoc """
  Thin, registry-validated HTTP port over `statsapi.mlb.com`. Every call goes
  through `get/3` which validates the endpoint name and params against
  `MlbFan.Stats.Endpoints`, builds the URL from the template (never from raw
  user/model text), and performs a retried `Req` GET. Concurrency/politeness is
  the caller's responsibility (bounded `Task.async_stream`).
  """

  require Logger

  alias MlbFan.Http
  alias MlbFan.Stats.Endpoints

  @timeout 15_000
  @max_retries 3
  @retry_base_ms 300

  @doc """
  Fetch an endpoint. `path_params` fill `{name}` slots; `query_params` become
  the query string. Returns `{:ok, decoded_body}` or `{:error, reason}`.
  """
  @spec get(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def get(name, path_params \\ %{}, query_params \\ %{}) do
    with {:ok, spec} <- Endpoints.fetch(name),
         :ok <- validate_required(spec, path_params, query_params),
         {:ok, url} <- build_url(spec, path_params, query_params) do
      do_get(url, 1)
    end
  end

  defp validate_required(spec, path_params, query_params) do
    provided =
      (Map.keys(path_params) ++ Map.keys(query_params))
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    missing = Enum.reject(spec.required, &MapSet.member?(provided, &1))
    if missing == [], do: :ok, else: {:error, {:missing_params, missing}}
  end

  defp build_url(spec, path_params, query_params) do
    path =
      Enum.reduce(spec.path_params, spec.path, fn key, acc ->
        value = path_params[key] || path_params[String.to_atom(key)]
        String.replace(acc, "{#{key}}", to_string(value))
      end)

    allowed = MapSet.new(spec.query_params)

    query =
      query_params
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.filter(fn {k, _v} -> MapSet.member?(allowed, k) end)

    url = Endpoints.base_url() <> path
    url = if query == [], do: url, else: url <> "?" <> URI.encode_query(query)
    {:ok, url}
  end

  defp do_get(url, attempt) do
    opts =
      Http.opts(
        url: url,
        receive_timeout: @timeout,
        headers: [{"accept", "application/json"}]
      )

    case Req.get(opts) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} when status in 500..599 and attempt < @max_retries ->
        backoff(attempt)
        do_get(url, attempt + 1)

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error(
          "MLB Stats API error status=#{status} url=#{sanitize(url)} body=#{inspect(body)}"
        )

        {:error, {:api_error, status}}

      {:error, _reason} when attempt < @max_retries ->
        backoff(attempt)
        do_get(url, attempt + 1)

      {:error, reason} ->
        Logger.error("MLB Stats request failed url=#{sanitize(url)} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp backoff(attempt), do: Process.sleep(@retry_base_ms * attempt)

  # statsapi needs no key, but keep URLs out of any accidental verbose logging path.
  defp sanitize(url), do: url |> URI.parse() |> Map.put(:query, nil) |> URI.to_string()
end
