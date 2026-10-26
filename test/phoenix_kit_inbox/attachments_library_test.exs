defmodule PhoenixKitInbox.AttachmentsLibraryTest do
  @moduledoc """
  The module's Storage library: shown in Media and managed (read-only) where
  the core can do it, hidden as before where it cannot, its name, and the
  module's own deletes in a managed library. The tests that need the core's
  managed libraries are skipped on a core without them.
  """

  use PhoenixKitInbox.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKitInbox.Attachments
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages

  Code.ensure_loaded(Libraries)

  @no_managed if(function_exported?(Libraries, :update_system_library_listing, 2),
                do: false,
                else: "needs a PhoenixKit core with managed hidden libraries"
              )

  # A core that has hidden libraries but no `media_listing:`/`managed:`.
  defmodule NoManagedLibraries do
    @moduledoc false
    alias PhoenixKit.Modules.Storage.Libraries

    defdelegate get_hidden_library_by_slug(slug), to: Libraries
    defdelegate hidden?(library), to: Libraries
    defdelegate media_uuid, to: Libraries

    def create_system_library(attrs, opts) do
      send(Application.get_env(:phoenix_kit_inbox, :library_test_pid), {:created_with, opts})
      Libraries.create_system_library(attrs, hidden: true)
    end
  end

  setup :storage_setup

  setup do
    enable_inbox!()

    on_exit(fn ->
      for key <- [:storage_libraries, :media_listing, :library_name, :library_test_pid],
          do: Application.delete_env(:phoenix_kit_inbox, key)
    end)

    :ok
  end

  defp site_library(name) do
    {:ok, library} = Libraries.create_system_library(%{"name" => name})
    library
  end

  # The library as an earlier version of the module made it.
  defp legacy_library(name \\ "PhoenixKit Inbox") do
    {:ok, library} =
      Libraries.create_system_library(%{"name" => name, "slug" => Attachments.library_slug()},
        hidden: true
      )

    library
  end

  describe "ensure_library/0 on a core with managed libraries" do
    @describetag skip: @no_managed

    test "makes a hidden library shown to uploaders and managed, named Mail attachments" do
      assert {:ok, library} = Attachments.ensure_library()

      assert library.name == "Mail attachments"
      assert Libraries.hidden?(library)
      assert Libraries.media_listing(library) == :uploaders
      assert Libraries.managed?(library)
    end

    test "the listing is the configured one" do
      Application.put_env(:phoenix_kit_inbox, :media_listing, :admins)
      assert {:ok, library} = Attachments.ensure_library()
      assert Libraries.media_listing(library) == :admins
    end

    test "a listing the core does not know is the default, with a warning" do
      Application.put_env(:phoenix_kit_inbox, :media_listing, :everybody)

      log =
        capture_log(fn ->
          assert {:ok, library} = Attachments.ensure_library()
          assert Libraries.media_listing(library) == :uploaders
        end)

      assert log =~ "media_listing"
    end

    test "the name is the configured one" do
      Application.put_env(:phoenix_kit_inbox, :library_name, "Letters")
      assert {:ok, library} = Attachments.ensure_library()
      assert library.name == "Letters"
    end

    test "a library made hidden-only is brought up to date, once" do
      old = legacy_library()
      assert Libraries.media_listing(old) == :none
      refute Libraries.managed?(old)

      assert {:ok, library} = Attachments.ensure_library()
      assert library.uuid == old.uuid
      assert library.name == "Mail attachments"
      assert Libraries.media_listing(library) == :uploaders
      assert Libraries.managed?(library)

      assert {:ok, again} = Attachments.ensure_library()
      assert again.updated_at == library.updated_at
      assert again.settings == library.settings
    end

    test "a changed config reaches an existing library" do
      assert {:ok, _} = Attachments.ensure_library()
      Application.put_env(:phoenix_kit_inbox, :media_listing, :own_only)

      assert {:ok, library} = Attachments.ensure_library()
      assert Libraries.media_listing(library) == :own_only
      assert Libraries.managed?(library)
    end

    test "a name chosen by someone else is not renamed" do
      legacy_library("Our mail files")

      assert {:ok, library} = Attachments.ensure_library()
      assert library.name == "Our mail files"
      assert Libraries.managed?(library)
    end

    test "a name taken by a site library: the library is made under a prefixed name" do
      site_library("Mail attachments")

      log =
        capture_log(fn ->
          assert {:ok, library} = Attachments.ensure_library()
          assert library.name != "Mail attachments"
          assert String.contains?(library.name, "Mail attachments")
          assert Libraries.managed?(library)
        end)

      assert log =~ "Mail attachments"
    end

    test "a name taken by a site library: an old library keeps its name" do
      old = legacy_library()
      site_library("Mail attachments")

      log =
        capture_log(fn ->
          assert {:ok, library} = Attachments.ensure_library()
          assert library.uuid == old.uuid
          assert library.name == "PhoenixKit Inbox"
          assert Libraries.managed?(library)
        end)

      assert log =~ "Mail attachments"
    end

    test "attachments work under the prefixed name" do
      site_library("Mail attachments")
      capture_log(fn -> assert {:ok, _} = Attachments.ensure_library() end)

      alice = user_fixture()
      bob = user_fixture()
      {:ok, box} = Mailboxes.ensure_user_mailbox(alice)
      {:ok, _} = Mailboxes.ensure_user_mailbox(bob)

      assert {:ok, message} =
               Messages.send_message(
                 scope_for(alice),
                 box,
                 %{"to" => "@#{bob.username}", "subject" => "Hi"},
                 attachments_data: [%{binary: "bytes", filename: "a.txt"}]
               )

      assert [_row] = Attachments.list_for_message(message.uuid)
    end
  end

  describe "ensure_library/0 on a core without managed libraries" do
    setup do
      Application.put_env(:phoenix_kit_inbox, :storage_libraries, NoManagedLibraries)
      Application.put_env(:phoenix_kit_inbox, :library_test_pid, self())
      :ok
    end

    test "the library stays hidden and plain, and the core is not asked for a listing" do
      assert {:ok, library} = Attachments.ensure_library()

      assert Libraries.hidden?(library)
      assert library.settings == %{}
      assert_received {:created_with, [hidden: true]}
    end

    test "an existing library is left as it is" do
      old = legacy_library()

      assert {:ok, library} = Attachments.ensure_library()
      assert library.uuid == old.uuid
      assert library.name == "PhoenixKit Inbox"
      assert library.settings == old.settings
    end
  end

  describe "deleting snapshots in a managed library" do
    @describetag skip: @no_managed

    setup do
      alice = user_fixture()
      {:ok, library} = Attachments.ensure_library()

      snapshot = stored_file_fixture(alice, "snapshot bytes", library_uuid: library.uuid)
      %{alice: alice, library: library, snapshot: snapshot}
    end

    test "the core refuses a user, the module's release/1 does not", %{snapshot: snapshot} do
      assert {:error, :managed} = Storage.delete_file_completely(snapshot)

      assert :ok = Attachments.release([snapshot.uuid])
      assert Storage.get_file(snapshot.uuid) == nil
    end

    test "discard_snapshots/1 deletes them too", %{snapshot: snapshot} do
      assert :ok = Attachments.discard_snapshots([snapshot.uuid])
      assert Storage.get_file(snapshot.uuid) == nil
    end

    test "a file outside the library is never deleted", %{alice: alice} do
      media = stored_file_fixture(alice, "media bytes")

      assert :ok = Attachments.release([media.uuid])
      assert %Storage.File{} = Storage.get_file(media.uuid)
    end
  end
end
