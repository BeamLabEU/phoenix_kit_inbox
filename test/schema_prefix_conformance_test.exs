defmodule PhoenixKitInbox.SchemaPrefixConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the runtime half of named-schema (`--prefix`) support: every
  table-backed schema must `use PhoenixKit.SchemaPrefix` so its queries
  target the schema core's migrations installed into. A schema missing
  it silently falls back to `search_path` resolution — invisible on
  public installs, broken on prefixed ones.

  inbox has no real schemas (the only match is the commented
  template in `lib/phoenix_kit_inbox/schemas/example_item.ex`),
  but this test ships with the template so modules copied from it keep
  the guard from day one.
  """

  test "every table-backed schema uses PhoenixKit.SchemaPrefix" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.filter(fn path ->
        content = File.read!(path)

        String.contains?(content, ~s[schema "phoenix_kit]) and
          not String.contains?(content, "use PhoenixKit.SchemaPrefix")
      end)

    assert offenders == [],
           "table-backed schemas missing `use PhoenixKit.SchemaPrefix` " <>
             "(add it right after `use Ecto.Schema`): #{inspect(offenders)}"
  end
end
