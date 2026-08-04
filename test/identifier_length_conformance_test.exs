defmodule PhoenixKitInbox.IdentifierLengthConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards every database identifier this module's migrations create against
  Postgres' 63-character limit.

  Postgres does not reject an over-long identifier — it silently **truncates**
  it to 63 bytes and logs a notice. That is worse than an error:

    * the resulting name is neither what the code says nor easily predictable
    * truncation happens per-database, so a name that changes later leaves
      already-migrated hosts on the old truncated name while fresh installs get
      the new one — two databases, two names, one index
    * a later `create_if_not_exists` keyed on the *untruncated* name doesn't
      match the truncated one, so it creates a second, duplicate index

  V01 shipped with exactly that bug:
  `phoenix_kit_inbox_deliveries_mailbox_uuid_folder_inserted_at_index` is 66
  characters. It now carries an explicit short name; this test is here so the
  next index nobody counts the characters of fails in CI instead of in a
  migration log.

  Ecto derives an unnamed index's name as `<table>_<col1>_<col2>_..._index`,
  which is what makes long composite indexes on long table names the usual
  offender — the same shape that bit V01.
  """

  @limit 63
  @migration_files Path.wildcard("lib/phoenix_kit_inbox/migrations/**/*.ex")

  test "migration files are actually being scanned" do
    # A silent zero-file glob would make every assertion below vacuously pass.
    assert @migration_files != [], "no migration files found — has the path moved?"
  end

  test "every explicit identifier name fits in #{@limit} characters" do
    offenders =
      for path <- @migration_files,
          {name, line} <- explicit_names(path),
          String.length(name) > @limit,
          do: {path, line, name, String.length(name)}

    assert offenders == [], format_offenders(offenders)
  end

  test "every derived index name fits in #{@limit} characters" do
    offenders =
      for path <- @migration_files,
          {name, line} <- derived_index_names(path),
          String.length(name) > @limit,
          do: {path, line, name, String.length(name)}

    assert offenders == [],
           format_offenders(offenders) <>
             "\n\nAn index without `name:` is named <table>_<cols>_index by Ecto. " <>
             "Give these an explicit short `name:`."
  end

  test "derived-name extraction actually finds the unnamed indexes" do
    # Protects the two tests above from silently passing because the regex
    # stopped matching after a refactor.
    all = Enum.flat_map(@migration_files, &derived_index_names/1)

    assert length(all) >= 5,
           "expected several unnamed indexes in V01, found #{length(all)} — " <>
             "the extraction regex has probably drifted"

    assert Enum.any?(all, fn {name, _} ->
             name == "phoenix_kit_inbox_mailboxes_kind_status_index"
           end),
           "known unnamed composite index was not extracted: got #{inspect(all)}"
  end

  # ── extraction ──────────────────────────────────────────────────────────────

  # `name: :some_identifier` — explicit names for indexes and constraints.
  defp explicit_names(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, number} ->
      case Regex.run(~r/name:\s*:([a-z0-9_]+)/, line) do
        [_, name] -> [{name, number}]
        nil -> []
      end
    end)
  end

  # `index(:table, [:a, :b], ...)` / `unique_index(...)` with no `name:` option.
  # Ecto derives `<table>_<a>_<b>_index`.
  #
  # The options may sit on following lines, so the `name:` check looks ahead a
  # few lines rather than only at the matched one — an explicit name written
  # under the column list must not be mistaken for a derived one.
  defp derived_index_names(path) do
    lines = path |> File.read!() |> String.split("\n")

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(&derived_index_on_line(&1, lines))
  end

  defp derived_index_on_line({line, number}, lines) do
    with [_, table, cols] <-
           Regex.run(~r/(?:unique_)?index\(\s*:([a-z0-9_]+),\s*\[([^\]]*)\]/, line),
         false <- named_nearby?(lines, number) do
      [{derive_name(table, cols), number}]
    else
      _ -> []
    end
  end

  defp derive_name(table, cols) do
    columns = ~r/:([a-z0-9_]+)/ |> Regex.scan(cols) |> Enum.map(fn [_, c] -> c end)

    Enum.join([table | columns] ++ ["index"], "_")
  end

  # `number` is 1-based; look at the matched line plus the next few, which is
  # where a multi-line call's `name:` option lives.
  defp named_nearby?(lines, number) do
    lines
    |> Enum.slice(max(number - 1, 0), 4)
    |> Enum.any?(&String.match?(&1, ~r/name:\s*:/))
  end

  defp format_offenders([]), do: ""

  defp format_offenders(offenders) do
    detail =
      Enum.map_join(offenders, "\n", fn {path, line, name, len} ->
        "  #{path}:#{line}  (#{len} chars) #{name}"
      end)

    "identifiers over Postgres' #{@limit}-character limit — " <>
      "Postgres will silently truncate these:\n" <> detail
  end
end
