defmodule PhoenixKitInbox.Web.CSPInlineTagsTest do
  @moduledoc """
  What a host's nonce-based Content-Security-Policy blocks stays out of this
  package: it renders no inline `<script>` or `<style>` (one would need the
  host's nonce) and no inline event handler, which no nonce can cover.
  Modelled on core's `PhoenixKitWeb.CSPInlineTagsTest`.

  HTML mail is not markup of a page. A message body is written by a person
  and reaches the page through the sanitizer; this test reads the sources
  only, and an outgoing mail is read by a mail client, where the host's
  policy does not apply.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @bundle "priv/static/assets/phoenix_kit_inbox.js"
  @doc_heredoc ~r/@(?:moduledoc|doc|typedoc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s

  # Files that may carry an inline tag without a nonce, each with its reason.
  # None today: the package renders no inline tag at all.
  @exempt []

  @tag_opening ~r/<(script|style)\b[^>]*>/s

  @events ~w(click dblclick change input submit reset invalid select focus blur focusin focusout
             keydown keyup keypress load error scroll wheel resize toggle contextmenu copy cut
             paste drop) ++
            ~w(mousedown mouseup mouseover mouseout mousemove mouseenter mouseleave) ++
            ~w(touchstart touchend touchmove pointerdown pointerup pointermove) ++
            ~w(dragstart dragend dragover dragenter dragleave animationend transitionend)
  @handler Regex.compile!("\\son[a-z]+=[\"'{]|\\son(?:#{Enum.join(@events, "|")})\\s*=\\s*[\"'{]")
  @js_url ~r/\b(?:href|src|action|formaction)\s*=\s*["'{]\s*["']?\s*javascript:/i

  test "no inline <script> or <style> in lib/ is written without a nonce" do
    offenders =
      for path <- sources(),
          path not in @exempt,
          {opening, number} <- tag_openings(path),
          not String.contains?(opening, "src="),
          not (opening =~ "CSP.nonce("),
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline tags without a nonce (add a helper that feature-detects core's " <>
             "`PhoenixKitWeb.CSP.nonce/1`, as phoenix_kit_billing does):\n" <>
             Enum.join(offenders, "\n")
  end

  test "no markup in lib/ carries an inline event handler" do
    offenders =
      for path <- sources(),
          {line, number} <- path |> read() |> code_lines(),
          not (line =~ ~r/^\s*(#|iex>|\.\.\.>)/),
          line =~ @handler or line =~ @js_url,
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline handlers (no nonce covers them; use a `phx-` binding, or a " <>
             "`data-pki-*` attribute handled in #{@bundle}):\n" <> Enum.join(offenders, "\n")
  end

  test "the patterns match what they are for" do
    assert ~S|<button phx-click="pick" onmousedown="event.preventDefault()">| =~ @handler
    assert ~S|<button onclick={"copy()"}>| =~ @handler
    assert ~S|<form onsubmit = 'return false'>| =~ @handler
    assert ~S|<a href="javascript:void(0)">| =~ @js_url
    refute ~S|<button phx-click="pick" data-pki-keep-focus>| =~ @handler
    refute ~S|only = "x"| =~ @handler

    assert Regex.match?(@tag_opening, "<style>") and
             Regex.match?(@tag_opening, "<script\n  defer>")
  end

  test "the bundle builds no inline handler and no <style> or <script>" do
    offenders =
      for {line, number} <- @bundle |> read() |> String.split("\n") |> Enum.with_index(1),
          not (line =~ ~r{^\s*(//|/?\*)}),
          line =~ ~r/\son[a-z]+=\\?["']/ or
            line =~ ~r/createElement\(["'](?:style|script)["']\)/ or
            line =~ ~r/["'`]<(?:style|script)\b/,
          do: "#{@bundle}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  defp sources do
    @root
    |> Path.join("lib/**/*.{ex,heex}")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, @root))
  end

  defp read(path), do: @root |> Path.join(path) |> File.read!()

  # Every opening `<script …>` / `<style …>` of the file with the line it starts on.
  defp tag_openings(path) do
    source = path |> read() |> markup_source()

    for [{start, length}] <- Regex.scan(@tag_opening, source, return: :index, capture: :first) do
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {binary_part(source, start, length), line}
    end
  end

  # The source with what is not markup blanked, line numbers kept: documentation, HEEx
  # comments and Elixir comment lines (a tag there is prose).
  defp markup_source(source) do
    blank = fn text -> String.replace(text, ~r/[^\n]/, "") end

    source
    |> then(&Regex.replace(@doc_heredoc, &1, blank))
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
    |> then(&Regex.replace(~r/^[ \t]*#[^\n]*$/m, &1, ""))
  end

  defp code_lines(source) do
    @doc_heredoc
    |> Regex.replace(source, fn doc -> String.replace(doc, ~r/[^\n]/, "") end)
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
