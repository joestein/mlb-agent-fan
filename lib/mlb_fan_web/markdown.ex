defmodule MlbFanWeb.Markdown do
  @moduledoc """
  Render assistant/LLM markdown to sanitized HTML. Model and web-derived text is
  UNTRUSTED (prompt-injection / XSS surface, spec §13): we convert markdown with
  Earmark then run an allowlist sanitizer, drop any non-http(s) links so
  `javascript:`/`data:` URIs can never render as clickable links, and drop
  `<img>` tags entirely (replacing them with their alt text) so attacker-
  influenced content cannot trigger tracking-pixel / remote-image egress from
  the user's browser on render.
  """

  @doc "Return sanitized HTML (safe) for the given markdown string."
  @spec to_safe_html(String.t()) :: Phoenix.HTML.safe()
  def to_safe_html(markdown) when is_binary(markdown) do
    markdown
    |> Earmark.as_html!(%Earmark.Options{escape: true, code_class_prefix: "language-"})
    |> HtmlSanitizeEx.markdown_html()
    |> drop_unsafe_links()
    |> drop_images()
    |> Phoenix.HTML.raw()
  end

  def to_safe_html(_), do: Phoenix.HTML.raw("")

  # Belt-and-suspenders: strip href attributes that are not http/https even if a
  # sanitizer variant let them through.
  defp drop_unsafe_links(html) do
    Regex.replace(~r/href="(?!https?:\/\/)[^"]*"/i, html, ~s(href="#"))
  end

  # Drop every rendered <img> (remote or not) to prevent tracking-pixel / IP
  # egress from attacker-influenced content; keep the alt text as inert text.
  defp drop_images(html) do
    Regex.replace(~r/<img\b[^>]*>/i, html, fn tag ->
      case Regex.run(~r/\balt="([^"]*)"/i, tag) do
        [_, alt] -> alt
        _ -> ""
      end
    end)
  end
end
