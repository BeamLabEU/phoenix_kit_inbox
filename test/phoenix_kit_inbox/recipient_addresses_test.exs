defmodule PhoenixKitInbox.RecipientAddressesTest do
  @moduledoc """
  `Mailboxes.recipient_addresses/2` is `recipient_address/2` for many users in
  one query: the same address for each, nothing for one that has none.
  """

  use PhoenixKitInbox.DataCase, async: true

  alias PhoenixKitInbox.Mailboxes

  test "gives each user the address the one-by-one lookup gives" do
    users = [
      user_fixture(%{username: "has_handle"}),
      user_fixture(%{username: "second_handle"}),
      user_fixture()
    ]

    uuids =
      Enum.map(users, & &1.uuid) ++
        [Ecto.UUID.generate(), "not-a-uuid", nil, 5, String.upcase(hd(users).uuid)]

    for route <- [:internal, :email] do
      batch = Mailboxes.recipient_addresses(uuids, route)

      for uuid <- uuids do
        expected =
          case Mailboxes.recipient_address(uuid, route) do
            {:ok, address} -> address
            {:error, _} -> nil
          end

        assert batch[uuid] == expected, "#{inspect(uuid)} by #{route}"
      end
    end
  end

  test "is one query, and none for nobody" do
    users = for _ <- 1..5, do: user_fixture()
    me = self()
    id = "recipient-addresses-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:phoenix_kit_inbox, :test, :repo, :query],
      fn _event, _measure, meta, _ ->
        if self() == me, do: send(me, {:query, meta.source})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    assert map_size(Mailboxes.recipient_addresses(Enum.map(users, & &1.uuid), :email)) == 5
    assert_receive {:query, "phoenix_kit_users"}
    refute_receive {:query, _}

    assert Mailboxes.recipient_addresses([], :email) == %{}
    assert Mailboxes.recipient_addresses(["junk"], :email) == %{}
    refute_receive {:query, _}
  end
end
