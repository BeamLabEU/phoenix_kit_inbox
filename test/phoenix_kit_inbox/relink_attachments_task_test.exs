defmodule PhoenixKitInbox.RelinkAttachmentsTaskTest do
  @moduledoc """
  The arguments and the printed report of
  `mix phoenix_kit_inbox.relink_attachments`. The work itself is
  `AttachmentsMaintenanceTest`.
  """

  use PhoenixKitInbox.LiveCase, async: false

  alias Mix.Tasks.PhoenixKitInbox.RelinkAttachments, as: Task
  alias PhoenixKit.Modules.Storage

  Code.ensure_loaded(Storage)

  @supported function_exported?(Storage, :relink_file, 3) and
               function_exported?(Storage, :delete_unreferenced_keys, 1)

  setup :storage_setup

  setup do
    enable_inbox!()
    {:ok, _} = PhoenixKitInbox.Attachments.ensure_library()
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)

    manifest = Path.join(System.tmp_dir!(), "task_#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(manifest) end)
    %{manifest: manifest}
  end

  defp output(kind) do
    receive do
      {:mix_shell, ^kind, [text]} -> text <> "\n" <> output(kind)
    after
      0 -> ""
    end
  end

  defp refused(argv) do
    assert {:shutdown, 1} = catch_exit(Task.run(argv))
    output(:error)
  end

  describe "on a core with relink_file" do
    @describetag skip: if(@supported, do: false, else: "needs Storage.relink_file/3")

    test "a dry run is the default and prints the report", %{manifest: manifest} do
      assert :ok = Task.run([])

      text = output(:info)
      assert text =~ "Dry run (nothing is written)"
      assert text =~ "snapshots with a donor: 0"
      assert text =~ "bytes to free by --purge-old: 0"
      assert text =~ "errors: 0"

      assert :ok = Task.run(["--dry-run", "--manifest", manifest])
      refute File.exists?(manifest)
    end

    test "--apply writes the manifest and says so", %{manifest: manifest} do
      assert :ok = Task.run(["--apply", "--manifest", manifest])

      assert output(:info) =~ "Phase 1 (applied)"
      assert %{"entries" => []} = manifest |> File.read!() |> Jason.decode!()
    end

    test "--purge-old reads the manifest and says what it did", %{manifest: manifest} do
      assert :ok = Task.run(["--apply", "--manifest", manifest])
      _ = output(:info)

      assert :ok = Task.run(["--purge-old", "--manifest", manifest])

      text = output(:info)
      assert text =~ "Phase 2 (applied)"
      assert text =~ "keys in the manifest: 0"
      assert :ok = Task.run(["--purge-old", "--dry-run", "--manifest", manifest])
      assert output(:info) =~ "Dry run (nothing is deleted)"
    end

    test "arguments that make no sense are refused before anything runs", %{manifest: manifest} do
      assert refused(["--apply"]) =~ "--manifest PATH is needed"
      assert refused(["--purge-old"]) =~ "--manifest PATH is needed"
      assert refused(["--apply", "--purge-old", "--manifest", manifest]) =~ "one at a time"
      assert refused(["--apply", "--dry-run", "--manifest", manifest]) =~ "exclude each other"
      assert refused(["--bogus"]) =~ "Invalid arguments"
      assert refused(["extra"]) =~ "unexpected argument"
      refute File.exists?(manifest)
    end

    test "a manifest that cannot be read is an error", %{manifest: manifest} do
      File.write!(manifest, "nope")

      assert refused(["--purge-old", "--manifest", manifest]) =~ "The manifest cannot be read"
      assert File.read!(manifest) == "nope"
    end
  end

  describe "on a core without relink_file" do
    @describetag skip: if(@supported, do: "the core has relink_file/3", else: false)

    test "the task says so and writes nothing", %{manifest: manifest} do
      assert refused([]) =~ "cannot do it"
      assert refused(["--apply", "--manifest", manifest]) =~ "nothing was done"
      refute File.exists?(manifest)
    end
  end
end
