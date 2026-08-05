defmodule PhoenixKitInbox.MailboxesTest do
  use PhoenixKitInbox.DataCase, async: true

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Schemas.Mailbox

  describe "ensure_user_mailbox/1" do
    test "creates a personal mailbox on first call and reuses it afterwards" do
      user = user_fixture()

      assert {:ok, %Mailbox{} = first} = Mailboxes.ensure_user_mailbox(user)
      assert first.kind == "user"
      assert first.owner_uuid == user.uuid
      assert first.address == user.email

      assert {:ok, second} = Mailboxes.ensure_user_mailbox(user)
      assert second.uuid == first.uuid
    end

    test "the slug is derived from the uuid, not the email — emails change" do
      user = user_fixture()
      {:ok, mailbox} = Mailboxes.ensure_user_mailbox(user)

      assert mailbox.slug == "u-" <> String.replace(user.uuid, "-", "")
    end

    test "rejects anything that isn't a user" do
      assert {:error, :invalid_user} = Mailboxes.ensure_user_mailbox(%{})
    end

    test "the personal-mailbox unique index rejects a second one for the same user" do
      user = user_fixture()
      {:ok, _} = Mailboxes.ensure_user_mailbox(user)

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Mailbox{
          name: "Sneaky second",
          slug: "sneaky-#{System.unique_integer([:positive])}",
          kind: "user",
          owner_uuid: user.uuid
        })
      end
    end
  end

  describe "shared mailboxes" do
    test "create_shared_mailbox/2 derives a slug from the name" do
      owner = user_fixture()

      assert {:ok, mailbox} =
               Mailboxes.create_shared_mailbox(owner.uuid, %{
                 name: "Customer Support",
                 address: "support@example.com"
               })

      assert mailbox.kind == "shared"
      assert mailbox.slug == "customer-support"
      assert mailbox.owner_uuid == owner.uuid
    end

    test "slugs are globally unique" do
      owner = user_fixture()
      {:ok, _} = Mailboxes.create_shared_mailbox(owner.uuid, %{name: "Sales"})

      assert {:error, changeset} = Mailboxes.create_shared_mailbox(owner.uuid, %{name: "Sales"})
      assert %{slug: _} = errors_on(changeset)
    end

    test "a user may own many shared mailboxes" do
      owner = user_fixture()

      assert {:ok, _} = Mailboxes.create_shared_mailbox(owner.uuid, %{name: "One"})
      assert {:ok, _} = Mailboxes.create_shared_mailbox(owner.uuid, %{name: "Two"})
    end

    test "personal mailboxes can't be archived — mail must have somewhere to land" do
      user = user_fixture()
      {:ok, personal} = Mailboxes.ensure_user_mailbox(user)

      assert {:error, :cannot_archive_personal_mailbox} = Mailboxes.archive_mailbox(personal)
    end

    test "archiving a shared mailbox removes it from the accessible list" do
      owner = user_fixture()
      {:ok, shared} = Mailboxes.create_shared_mailbox(owner.uuid, %{name: "Temp"})

      assert shared.uuid in mailbox_uuids(owner)
      assert {:ok, _} = Mailboxes.archive_mailbox(shared)
      refute shared.uuid in mailbox_uuids(owner)
    end
  end

  describe "access control" do
    setup do
      owner = user_fixture()
      other = user_fixture()
      {:ok, shared} = Mailboxes.create_shared_mailbox(owner.uuid, %{name: "Support Desk"})

      %{owner: owner, other: other, shared: shared}
    end

    test "the owner holds admin without any grant row", %{owner: owner, shared: shared} do
      assert Mailboxes.access_level(shared, owner.uuid) == "admin"
      assert Mailboxes.list_grants(shared.uuid) == []
    end

    test "a stranger holds nothing", %{other: other, shared: shared} do
      assert Mailboxes.access_level(shared, other.uuid) == nil
      assert {:error, :mailbox_access_denied} = Mailboxes.authorize(shared, other.uuid, "read")
    end

    test "granting read allows read but not write", %{other: other, shared: shared, owner: owner} do
      {:ok, _} =
        Mailboxes.grant_access(shared.uuid, other.uuid, "read", granted_by_uuid: owner.uuid)

      assert :ok = Mailboxes.authorize(shared, other.uuid, "read")
      assert {:error, :mailbox_access_denied} = Mailboxes.authorize(shared, other.uuid, "write")
    end

    test "admin covers every weaker level", %{other: other, shared: shared} do
      {:ok, _} = Mailboxes.grant_access(shared.uuid, other.uuid, "admin")

      assert :ok = Mailboxes.authorize(shared, other.uuid, "read")
      assert :ok = Mailboxes.authorize(shared, other.uuid, "write")
      assert :ok = Mailboxes.authorize(shared, other.uuid, "admin")
    end

    test "re-granting updates the level instead of duplicating the row", %{
      other: other,
      shared: shared
    } do
      {:ok, _} = Mailboxes.grant_access(shared.uuid, other.uuid, "read")
      {:ok, _} = Mailboxes.grant_access(shared.uuid, other.uuid, "write")

      assert length(Mailboxes.list_grants(shared.uuid)) == 1
      assert Mailboxes.access_level(shared, other.uuid) == "write"
    end

    test "revoking is idempotent", %{other: other, shared: shared} do
      {:ok, _} = Mailboxes.grant_access(shared.uuid, other.uuid, "read")

      assert :ok = Mailboxes.revoke_access(shared.uuid, other.uuid)
      assert :ok = Mailboxes.revoke_access(shared.uuid, other.uuid)
      assert Mailboxes.access_level(shared, other.uuid) == nil
    end

    test "a granted mailbox shows up in the sidebar list", %{other: other, shared: shared} do
      {:ok, _} = Mailboxes.ensure_user_mailbox(other)
      {:ok, _} = Mailboxes.grant_access(shared.uuid, other.uuid, "read")

      assert shared.uuid in mailbox_uuids(other)
    end

    test "personal mailboxes sort before shared ones", %{owner: owner} do
      {:ok, personal} = Mailboxes.ensure_user_mailbox(owner)

      assert [first | _] = Mailboxes.list_accessible_mailboxes(owner.uuid)
      assert first.uuid == personal.uuid
    end
  end

  describe "recipient resolution" do
    test "matches on address or slug, case-insensitively" do
      owner = user_fixture()

      {:ok, shared} =
        Mailboxes.create_shared_mailbox(owner.uuid, %{
          name: "Billing",
          address: "billing@example.com"
        })

      assert {:ok, %{uuid: uuid}} = Mailboxes.fetch_mailbox_by_recipient("billing")
      assert uuid == shared.uuid

      assert {:ok, %{uuid: ^uuid}} = Mailboxes.fetch_mailbox_by_recipient("BILLING@example.com")
      assert {:ok, %{uuid: ^uuid}} = Mailboxes.fetch_mailbox_by_recipient("  billing  ")
    end

    test "an unknown handle is an error, not nil" do
      assert {:error, :recipient_not_found} = Mailboxes.fetch_mailbox_by_recipient("nobody-here")
    end

    test "archived mailboxes stop resolving" do
      owner = user_fixture()
      {:ok, shared} = Mailboxes.create_shared_mailbox(owner.uuid, %{name: "Old Desk"})
      {:ok, _} = Mailboxes.archive_mailbox(shared)

      assert {:error, :recipient_not_found} = Mailboxes.fetch_mailbox_by_recipient("old-desk")
    end

    test "a shared mailbox resolves by its display name, not only its slug" do
      owner = user_fixture()
      {:ok, shared} = Mailboxes.create_shared_mailbox(owner.uuid, %{name: "Customer Support"})

      assert {:ok, %{uuid: uuid}} = Mailboxes.fetch_mailbox_by_recipient("Customer Support")
      assert uuid == shared.uuid
      assert {:ok, %{uuid: ^uuid}} = Mailboxes.fetch_mailbox_by_recipient("customer support")
    end

    test "a username resolves — the case that reported 'no mailbox matches'" do
      user = user_fixture(%{username: "fotkin", email: "fotkin@example.com"})
      {:ok, mailbox} = Mailboxes.ensure_user_mailbox(user)

      assert {:ok, %{uuid: uuid}} = Mailboxes.fetch_mailbox_by_recipient("fotkin")
      assert uuid == mailbox.uuid
    end

    test "a username resolves case-insensitively and ignores surrounding space" do
      user = user_fixture(%{username: "fotkin", email: "fotkin@example.com"})
      {:ok, mailbox} = Mailboxes.ensure_user_mailbox(user)

      for typed <- ["FOTKIN", "Fotkin", "  fotkin  "] do
        assert {:ok, %{uuid: uuid}} = Mailboxes.fetch_mailbox_by_recipient(typed),
               "#{inspect(typed)} did not resolve"

        assert uuid == mailbox.uuid
      end
    end

    test "a user who has never opened Inbox is still addressable" do
      # The mailbox is created lazily on first visit, so before this fix a
      # colleague who had not clicked the tab was unreachable by ANY spelling.
      user = user_fixture(%{username: "newcomer", email: "newcomer@example.com"})

      assert Mailboxes.list_accessible_mailboxes(user.uuid) == []

      assert {:ok, mailbox} = Mailboxes.fetch_mailbox_by_recipient("newcomer")
      assert mailbox.owner_uuid == user.uuid
      assert mailbox.kind == "user"
    end

    test "resolving the same absent user twice returns one mailbox, not two" do
      user = user_fixture(%{username: "newcomer2", email: "newcomer2@example.com"})

      assert {:ok, first} = Mailboxes.fetch_mailbox_by_recipient("newcomer2")
      assert {:ok, second} = Mailboxes.fetch_mailbox_by_recipient("newcomer2@example.com")

      assert first.uuid == second.uuid
    end

    test "an email resolves for a user with no mailbox yet" do
      user = user_fixture(%{username: "byemail", email: "byemail@example.com"})

      assert {:ok, mailbox} = Mailboxes.fetch_mailbox_by_recipient("ByEmail@example.com")
      assert mailbox.owner_uuid == user.uuid
    end

    test "an inactive user is not addressable" do
      user_fixture(%{username: "retired", email: "retired@example.com", is_active: false})

      assert {:error, :recipient_not_found} = Mailboxes.fetch_mailbox_by_recipient("retired")
    end

    test "a blank term never resolves" do
      for typed <- ["", "   "] do
        assert {:error, :recipient_not_found} = Mailboxes.fetch_mailbox_by_recipient(typed)
      end
    end
  end

  describe "search_recipients/3 (compose suggestions)" do
    test "offers users who have no mailbox yet" do
      me = user_fixture()
      them = user_fixture(%{username: "suggestme", email: "suggestme@example.com"})

      handles = me.uuid |> Mailboxes.search_recipients() |> Enum.map(& &1.handle)

      assert "suggestme" in handles
      assert Mailboxes.list_accessible_mailboxes(them.uuid) == []
    end

    test "every suggested handle actually resolves" do
      me = user_fixture()
      user_fixture(%{username: "resolvable", email: "resolvable@example.com"})
      {:ok, _} = Mailboxes.create_shared_mailbox(me.uuid, %{name: "Helpdesk"})

      for %{handle: handle} <- Mailboxes.search_recipients(me.uuid) do
        assert {:ok, _mailbox} = Mailboxes.fetch_mailbox_by_recipient(handle),
               "suggested handle #{inspect(handle)} does not resolve"
      end
    end

    test "does not suggest the sender to themselves" do
      me = user_fixture(%{username: "myself", email: "myself@example.com"})

      handles = me.uuid |> Mailboxes.search_recipients() |> Enum.map(& &1.handle)

      refute "myself" in handles
    end

    test "filters on username, email and name" do
      me = user_fixture()

      user_fixture(%{
        username: "zzfindme",
        email: "zzfindme@example.com",
        first_name: "Zaphod",
        last_name: "Beeblebrox"
      })

      for term <- ["zzfindme", "zzfindme@exam", "Zaphod", "Beeblebrox"] do
        handles = me.uuid |> Mailboxes.search_recipients(term) |> Enum.map(& &1.handle)
        assert "zzfindme" in handles, "term #{inspect(term)} did not surface the user"
      end
    end

    test "shared mailboxes are offered by slug and labelled as shared" do
      me = user_fixture()
      {:ok, _} = Mailboxes.create_shared_mailbox(me.uuid, %{name: "Night Desk"})

      suggestion =
        me.uuid
        |> Mailboxes.search_recipients("night")
        |> Enum.find(&(&1.handle == "night-desk"))

      assert suggestion
      assert suggestion.label =~ "shared mailbox"
    end

    test "a blank term lists candidates rather than nothing" do
      me = user_fixture()
      user_fixture(%{username: "listed", email: "listed@example.com"})

      assert me.uuid |> Mailboxes.search_recipients("") |> length() > 0
    end

    test "respects the limit" do
      me = user_fixture()
      for _ <- 1..5, do: user_fixture()

      assert me.uuid |> Mailboxes.search_recipients("", limit: 2) |> length() <= 2
    end
  end

  describe "user_display_name/1" do
    test "prefers the full name, then username, then the email local part" do
      assert Mailboxes.user_display_name(%{first_name: "Ada", last_name: "Lovelace"}) ==
               "Ada Lovelace"

      assert Mailboxes.user_display_name(%{username: "ada", email: "ada@example.com"}) == "ada"
      assert Mailboxes.user_display_name(%{email: "ada@example.com"}) == "ada"
    end
  end

  defp mailbox_uuids(user) do
    user.uuid |> Mailboxes.list_accessible_mailboxes() |> Enum.map(& &1.uuid)
  end
end
