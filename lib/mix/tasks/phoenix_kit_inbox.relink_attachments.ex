defmodule Mix.Tasks.PhoenixKitInbox.RelinkAttachments do
  @moduledoc """
  Moves the Inbox library's full-copy snapshots onto the stored objects of the
  Storage file they were copied from, and files every sent message's
  attachments in folders. See `PhoenixKitInbox.Attachments.Maintenance`.

  Dry-run by default: prints what would be done and writes nothing.

  ## Usage

      $ mix phoenix_kit_inbox.relink_attachments
      $ mix phoenix_kit_inbox.relink_attachments --apply --manifest relink.json
      $ mix phoenix_kit_inbox.relink_attachments --purge-old --manifest relink.json

  ## Options

    * `--dry-run` - Report only (the default)
    * `--apply` - Phase 1: relink the snapshots, file the messages, write the
      manifest (needs `--manifest`; an existing manifest is added to) and
      check every relinked file by its sha256. The old objects stay.
    * `--purge-old` - Phase 2: delete the old objects the manifest names that
      nothing names any more (needs `--manifest`; with `--dry-run` only counts
      them)
    * `--manifest` - The manifest's path

  `--apply` checks the manifest can be written before it moves anything, adds
  each record to it as it goes, and when run again re-checks the entries that
  never verified. A dry run only reads. `--purge-old` never deletes a key an
  unverified entry names, nor one that is not a plain key under the library's
  prefix.

  Before `--purge-old`, keep the database dump from before `--apply` and copy
  the library's directory in the bucket: until then the old objects are all
  still there. Run it again as often as needed: a second run changes nothing.

  Exits `1` on invalid arguments, on a core without `Storage.relink_file/3`,
  and when a record could not be relinked, checked or filed.
  """

  use Mix.Task

  alias PhoenixKitInbox.Attachments.Maintenance

  @shortdoc "Relink the Inbox library's snapshots to Media's objects and file them in folders"

  @switches [dry_run: :boolean, apply: :boolean, purge_old: :boolean, manifest: :string]

  # Parsed and validated before the app starts, so a typo never runs a phase.
  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [], []} -> validate_and_run(opts)
      {_opts, rest, errors} -> halt_with_error(invalid_message(rest, errors))
    end
  end

  defp validate_and_run(opts) do
    case validate(opts) do
      {:ok, mode} ->
        Mix.Task.run("app.start")
        run_mode(mode, opts[:manifest])

      {:error, message} ->
        halt_with_error(message)
    end
  end

  defp validate(opts) do
    case {opts[:apply] == true, opts[:purge_old] == true, opts[:dry_run] == true} do
      {true, true, _} ->
        {:error, "--apply and --purge-old are two phases: run them one at a time"}

      {true, _, true} ->
        {:error, "--apply and --dry-run exclude each other"}

      {true, _, _} ->
        with :ok <- need_manifest(opts), do: {:ok, :apply}

      {_, true, dry?} ->
        with :ok <- need_manifest(opts), do: {:ok, purge_mode(dry?)}

      _ ->
        {:ok, :dry_run}
    end
  end

  defp purge_mode(true), do: :purge_dry_run
  defp purge_mode(false), do: :purge

  defp need_manifest(opts),
    do: if(opts[:manifest], do: :ok, else: {:error, "--manifest PATH is needed"})

  defp invalid_message(rest, errors) do
    parts =
      Enum.map(errors, fn
        {switch, nil} -> "invalid option #{switch}"
        {switch, value} -> "invalid value #{inspect(value)} for #{switch}"
      end) ++ Enum.map(rest, &"unexpected argument #{inspect(&1)}")

    "Invalid arguments: " <> Enum.join(parts, "; ")
  end

  defp run_mode(mode, manifest) when mode in [:dry_run, :apply] do
    apply? = mode == :apply

    case Maintenance.relink(apply: apply?, manifest: manifest) do
      {:ok, report} ->
        Mix.shell().info(format_relink(report))
        halt_unless_clean(report.errors)

      {:error, reason} ->
        halt_with_error(error_message(reason))
    end
  end

  defp run_mode(mode, manifest) do
    case Maintenance.purge_old(manifest, apply: mode == :purge) do
      {:ok, report} ->
        Mix.shell().info(format_purge(report))
        halt_unless_clean(report.errors)

      {:error, reason} ->
        halt_with_error(error_message(reason))
    end
  end

  @doc false
  @spec format_relink(map()) :: String.t()
  def format_relink(report) do
    verb = if report.apply?, do: "relinked", else: "to relink"
    filed = if report.apply?, do: "filed in folders", else: "messages to file in folders"

    lines =
      [
        if(report.apply?, do: "Phase 1 (applied)", else: "Dry run (nothing is written)"),
        "  snapshots with a donor: #{report.records}",
        "  #{verb}: #{report.relinked}",
        "  without a donor, left as they are: #{report.without_donor}",
        "  skipped (not an error): #{length(report.skipped)}",
        "  #{filed}: #{report.laid_out}",
        if(report.apply?, do: "  read back, sha256 matches: #{report.verified}"),
        "  bytes to free by --purge-old: #{report.bytes}",
        if(report.manifest, do: "  manifest: #{report.manifest}"),
        "  errors: #{length(report.errors)}"
      ] ++
        Enum.map(report.skipped, &"    skipped: #{&1}") ++
        Enum.map(report.errors, &"    - #{&1}")

    lines |> Enum.reject(&is_nil/1) |> Enum.join("\n")
  end

  @doc false
  @spec format_purge(map()) :: String.t()
  def format_purge(report) do
    deleted = if report.apply?, do: "deleted", else: "to delete"

    ([
       if(report.apply?, do: "Phase 2 (applied)", else: "Dry run (nothing is deleted)"),
       "  keys in the manifest: #{report.keys}",
       "  dropped, outside the library's key prefix: #{report.outside_prefix}",
       "  skipped, their records did not verify: #{report.unverified}",
       "  kept, named again: #{report.kept}",
       "  already gone: #{report.already_gone}",
       "  #{deleted}: #{report.deleted}",
       "  kept by Storage, named again meanwhile: #{report.left}",
       "  errors: #{length(report.errors)}"
     ] ++ Enum.map(report.errors, &"    - #{&1}"))
    |> Enum.join("\n")
  end

  @doc false
  @spec error_message(term()) :: String.t()
  def error_message(:core_unsupported),
    do:
      "This PhoenixKit core cannot do it (Storage.relink_file/3 and delete_unreferenced_keys/1 are missing); nothing was done."

  def error_message(:manifest_other_library),
    do: "The manifest is not of this installation's attachments library; nothing was done."

  def error_message({:manifest_unwritable, reason}),
    do: "The manifest cannot be written: #{inspect(reason)}; nothing was done."

  def error_message(:manifest_version),
    do: "The manifest is of a format this version does not know; nothing was done."

  def error_message({:manifest_locked, lock}),
    do: "Another run is using this manifest (#{lock}); if none is, delete that file."

  def error_message(:no_library), do: "There is no attachments library; nothing to do."
  def error_message(:manifest_required), do: "--manifest PATH is needed"

  def error_message(:no_key_prefix),
    do: "The attachments library has no key prefix; nothing was done."

  def error_message({:manifest_unreadable, reason}),
    do: "The manifest cannot be read: #{inspect(reason)}"

  # Anything else the maintenance may one day answer is printed, not a crash.
  @dialyzer {:nowarn_function, error_message: 1}
  def error_message(reason), do: "Failed: #{inspect(reason)}"

  defp halt_unless_clean([]), do: :ok
  defp halt_unless_clean(_errors), do: exit({:shutdown, 1})

  defp halt_with_error(message) do
    Mix.shell().error(message)
    exit({:shutdown, 1})
  end
end
