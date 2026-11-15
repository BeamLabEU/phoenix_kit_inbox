defmodule PhoenixKitInbox.CorePinConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the `:phoenix_kit` requirement against being re-narrowed to a
  single core MINOR.

  The trap is the three-segment form: `~> 3.5.x` expands to
  `>= 3.5.x and < 3.6.0`, so no 3.6 or later core satisfies it. The breakage
  lands on consumers, not here — a host depending on both this module and a
  newer core minor gets an unsolvable dependency set and `mix deps.get`
  fails outright. Nothing else in this repo's own test run would notice,
  because the workspace always resolves the latest core.

  The requirement is `>= 3.5.0 and < 4.0.0`. The floor is the minimum core
  every PhoenixKit module requires; it carries everything this module builds
  on without a run-time check: hidden system libraries, `dedup: false`,
  `Storage.link_copy/3`, managed libraries, `Storage.relink_file/3` and
  `delete_unreferenced_keys/1` (the maintenance task calls the last two
  directly). The ceiling is open through every core 3.x.
  """

  @floor "3.5.0"
  @must_admit ["3.5.0", "3.5.1", "3.6.0", "3.9.9"]
  @must_reject ["2.0.0", "2.64.0", "2.99.4", "3.0.0", "3.4.0", "3.4.9", "4.0.0"]

  # `PHOENIX_KIT_PATH` swaps the pin for a path dep (`pk_dep/3` in mix.exs),
  # which carries no requirement to check.
  @moduletag skip: if(System.get_env("PHOENIX_KIT_PATH"), do: "PHOENIX_KIT_PATH is set")

  test "the phoenix_kit requirement admits every core 3.x at or above the floor" do
    requirement = core_requirement()

    assert match?({:ok, _parsed}, Version.parse_requirement(requirement)),
           "`:phoenix_kit` requirement #{inspect(requirement)} is not a valid version requirement"

    for version <- @must_admit do
      assert Version.match?(version, requirement),
             "`:phoenix_kit` requirement #{inspect(requirement)} rejects core #{version}. " <>
               "A pin that excludes a core minor at or above the floor breaks `mix deps.get` " <>
               "for every host running this module alongside that core. Keep the floor " <>
               "patch-precise and the ceiling open (`>= 3.5.0 and < 4.0.0`), never a " <>
               "three-segment `~>`."
    end

    for version <- @must_reject do
      refute Version.match?(version, requirement),
             "`:phoenix_kit` requirement #{inspect(requirement)} admits core #{version}, " <>
               "which is outside the range this module is verified against " <>
               "(floor #{@floor}, next unreleased major excluded)."
    end
  end

  defp core_requirement do
    Mix.Project.config()
    |> Keyword.fetch!(:deps)
    |> Enum.find_value(fn
      {:phoenix_kit, requirement} when is_binary(requirement) -> requirement
      {:phoenix_kit, requirement, _opts} when is_binary(requirement) -> requirement
      _ -> nil
    end)
    |> case do
      nil ->
        raise """
        No binary version requirement found for `:phoenix_kit` in mix.exs deps.
        A committed `path:` dep ships a broken package — use PHOENIX_KIT_PATH
        (pk_dep/3) for local development instead.
        """

      requirement ->
        requirement
    end
  end
end
