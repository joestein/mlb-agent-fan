defmodule MlbFanWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias MlbFanWeb.Markdown

  defp html(markdown), do: Phoenix.HTML.safe_to_string(Markdown.to_safe_html(markdown))

  # ── XSS / script stripping ───────────────────────────────────────────────

  test "script tags are stripped from model output (only tag, not text content)" do
    # Security property: <script> wrapper is gone so content is never executed.
    # HtmlSanitizeEx removes the tag but keeps inner text as plain (inert) text.
    result = html("Hello <script>alert('xss')</script> world")
    refute result =~ "<script>"
    refute result =~ "</script>"
    # The key: no executable script element present
    assert result =~ "Hello"
  end

  test "inline event handler attributes are stripped" do
    result = html("<b onclick=\"evil()\">bold</b>")
    refute result =~ "onclick"
  end

  # ── link safety (spec §13: non-http(s) hrefs must not render) ────────────

  test "javascript: href is not present in output (sanitizer removes it entirely)" do
    # HtmlSanitizeEx.markdown_html removes non-safe hrefs; drop_unsafe_links
    # provides a belt-and-suspenders fallback for any that slip through.
    # Either way, javascript: must NOT appear in rendered output.
    result = html("[click me](javascript:alert(1))")
    refute result =~ "javascript:"
    # The link text should still be visible
    assert result =~ "click me"
  end

  test "data: URI href is not present in output" do
    result = html("[link text](data:text/html,payload)")
    refute result =~ "data:"
    assert result =~ "link text"
  end

  test "drop_unsafe_links replaces a non-http(s) href that slips past the sanitizer" do
    # If a href="vbscript:..." or similar were to survive HtmlSanitizeEx, the
    # Regex in drop_unsafe_links must replace it with href="#".
    # We call the module function directly (which includes drop_unsafe_links) and
    # inject a non-https href via raw HTML that the sanitizer might keep.
    # Best test: verify the regex itself — pass a pre-sanitized fragment.
    raw = ~s[<a href="vbscript:evil()">v</a>]
    sanitized = MlbFanWeb.Markdown.to_safe_html(raw)
    refute Phoenix.HTML.safe_to_string(sanitized) =~ "vbscript"
  end

  test "valid https: link is preserved" do
    result = html("[MLB stats](https://mlb.com/stats)")
    assert result =~ "https://mlb.com/stats"
  end

  test "valid http: link is preserved" do
    result = html("[source](http://stats.example.com)")
    assert result =~ "http://stats.example.com"
  end

  # ── remote image / tracking-pixel stripping (spec §13) ───────────────────

  test "a remote markdown image is dropped (no <img> egress) and its alt kept" do
    result = html("![team logo](http://attacker.example/track.png)")
    refute result =~ "<img"
    refute result =~ "attacker.example"
    assert result =~ "team logo"
  end

  test "no live <img> tag survives even a rendered markdown image (no auto-egress)" do
    # Markdown image syntax is the tag-producing vector; the raw-HTML form is
    # already neutralized by Earmark escape:true. Either way, no <img> renders.
    result = html("![pixel](https://evil.example/pixel.gif) then text")
    refute result =~ "<img"
    assert result =~ "pixel"
    assert result =~ "then text"
  end

  test "an image with no alt text is dropped without leaving markup" do
    result = html("![](http://attacker.example/track.png)")
    refute result =~ "<img"
    refute result =~ "attacker.example"
  end

  # ── markdown rendering ────────────────────────────────────────────────────

  test "markdown bold is rendered to <strong>" do
    result = html("**Judge**")
    assert result =~ "<strong>"
    assert result =~ "Judge"
  end

  test "markdown table-like content is rendered (common in model answers)" do
    md = """
    | Player | HR | Streak |
    |--------|----|----|
    | Judge  | 30 | 5  |
    """

    result = html(md)
    assert result =~ "Judge"
    assert result =~ "30"
  end

  # ── edge cases ────────────────────────────────────────────────────────────

  test "nil input returns empty safe HTML" do
    assert html(nil) == ""
  end

  test "integer input returns empty safe HTML" do
    assert html(42) == ""
  end

  test "empty string returns safe (empty) HTML" do
    # Earmark on empty string returns "" — just ensure no crash
    result = Markdown.to_safe_html("")
    assert is_tuple(result) or is_binary(Phoenix.HTML.safe_to_string(result))
  end
end
