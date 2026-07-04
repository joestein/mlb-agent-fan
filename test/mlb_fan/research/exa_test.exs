defmodule MlbFan.Research.ExaTest do
  use ExUnit.Case, async: true

  # Uses Req.Test (needs the :req app started), so excluded from the --no-start
  # `mix test.unit` suite; runs under the full `mix test`.
  @moduletag :req

  alias MlbFan.Research.Exa

  setup do
    prev = Application.get_env(:mlb_fan, :exa)
    Application.put_env(:mlb_fan, :exa, api_key: "test-exa-key", type: "auto")
    on_exit(fn -> Application.put_env(:mlb_fan, :exa, prev) end)
    :ok
  end

  test "search parses results and filters out non-http(s) URLs (XSS/SSRF guard)" do
    Req.Test.stub(MlbFan.ReqStub, fn conn ->
      Req.Test.json(conn, %{
        "results" => [
          %{
            "title" => "Judge HR watch",
            "url" => "https://mlb.com/a",
            "text" => "hot",
            "publishedDate" => "2026-07-01"
          },
          %{"title" => "evil", "url" => "javascript:alert(1)", "text" => "x"},
          %{"title" => "data uri", "url" => "data:text/html,<script>", "text" => "x"}
        ]
      })
    end)

    assert {:ok, [only]} = Exa.search("Aaron Judge home runs", num_results: 4)
    assert only.url == "https://mlb.com/a"
    assert only.title == "Judge HR watch"
  end

  test "search returns empty (no crash) when no API key configured" do
    Application.put_env(:mlb_fan, :exa, api_key: nil)
    assert {:ok, []} = Exa.search("anything")
  end

  test "dedup_by_domain caps results per host, preserving order" do
    results = [
      %{url: "https://a.com/1"},
      %{url: "https://a.com/2"},
      %{url: "https://a.com/3"},
      %{url: "https://b.com/1"}
    ]

    kept = Exa.dedup_by_domain(results, 2)
    assert length(kept) == 3
    assert Enum.map(kept, & &1.url) == ["https://a.com/1", "https://a.com/2", "https://b.com/1"]
  end
end
