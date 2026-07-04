defmodule MlbFan.Http do
  @moduledoc """
  Central place to build `Req` options so every outbound client can be routed
  through a `Req.Test` stub in tests (zero network egress) while using the real
  network in dev/prod. Never logs headers or bodies — secrets are passed as
  header values by callers and must never be inspected here.

  Defense-in-depth egress allowlist (spec §13 / OWASP A10): when a real request
  is about to go out (no `Req.Test` plug configured), its host must be one of the
  three sanctioned upstreams. A future client added without going through the
  endpoint registry / fixed base URLs is caught here rather than silently
  reaching an arbitrary host.
  """

  # The only hosts this app is ever allowed to reach.
  @allowed_hosts ~w(statsapi.mlb.com api.anthropic.com api.exa.ai)

  @doc """
  Merge caller options with the configured test plug (if any). In `:test` the
  app config sets `:req_plug` to `{Req.Test, MlbFan.ReqStub}`; the request is
  routed to the stub (any un-stubbed request raises) and the host allowlist is
  bypassed. Outside tests (no plug), the request host is asserted against the
  allowlist before the options are returned.
  """
  @spec opts(keyword()) :: keyword()
  def opts(extra \\ []) do
    case Application.get_env(:mlb_fan, :req_plug) do
      nil ->
        assert_allowed_host!(Keyword.get(extra, :url))
        extra

      plug ->
        Keyword.put(extra, :plug, plug)
    end
  end

  @doc "The sanctioned outbound hosts."
  @spec allowed_hosts() :: [String.t()]
  def allowed_hosts, do: @allowed_hosts

  @doc "True if `url`'s host is on the egress allowlist."
  @spec allowed_host?(String.t() | nil) :: boolean()
  def allowed_host?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.downcase(host) in @allowed_hosts
      _ -> false
    end
  end

  def allowed_host?(_), do: false

  defp assert_allowed_host!(url) do
    unless allowed_host?(url) do
      raise ArgumentError,
            "outbound request to disallowed host (egress allowlist): #{inspect(host_of(url))}"
    end
  end

  defp host_of(url) when is_binary(url), do: URI.parse(url).host
  defp host_of(_), do: nil
end
