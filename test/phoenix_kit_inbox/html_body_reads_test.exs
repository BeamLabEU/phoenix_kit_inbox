defmodule PhoenixKitInbox.HtmlBodyReadsTest do
  @moduledoc """
  The host's `html_body` (kept for the retry of an external email, up to 256
  KiB) is for the email only: the lists a person reads do not carry it out of
  the database, not even to throw it away.
  """

  use PhoenixKitInbox.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.Message

  @order %{kind: "order", ref: "o-1"}
  @marker "HTML-BODY-MARKER"

  setup do
    enable_inbox!()
    alice = user_fixture()
    bob = user_fixture()
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)

    {:ok, message} =
      Messages.send_message(
        scope_for(bob),
        bob_mb,
        %{"to" => "@" <> alice.username, "subject" => "Offer", "body" => "Body"},
        links: [@order]
      )

    html = String.duplicate(@marker, div(200 * 1024, byte_size(@marker)))

    Repo.update_all(
      from(m in Message, where: m.uuid == ^message.uuid),
      set: [metadata: Map.put(message.metadata, "html_body", html)]
    )

    %{
      alice: alice,
      alice_mb: alice_mb,
      bob_mb: bob_mb,
      message: message,
      alice_scope: scope_for(alice),
      bob_scope: scope_for(bob)
    }
  end

  # What the database sends back for `fun`: the queries and everything they
  # returned, so a column read and then dropped shows.
  defp traced(fun) do
    parent = self()
    handler = "html-body-reads-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measurements, metadata, _config ->
          if self() == parent, do: send(parent, {:query_result, metadata[:result]})
        end,
        nil
      )

    try do
      result = fun.()
      {result, collect([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp collect(acc) do
    receive do
      {:query_result, result} -> collect([result | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp carried?(results), do: results |> inspect(limit: :infinity) |> String.contains?(@marker)

  test "a folder list, one message and a thread do not read it", ctx do
    {listed, queries} = traced(fn -> Messages.list_folder(ctx.alice_mb.uuid, "inbox") end)
    assert [%{message: %{metadata: metadata}}] = listed
    refute Map.has_key?(metadata, "html_body")
    refute carried?(queries)

    {_, queries} =
      traced(fn -> Messages.fetch_for_mailbox(ctx.alice_mb.uuid, ctx.message.uuid) end)

    refute carried?(queries)

    {_, queries} = traced(fn -> Messages.fetch_for_scope(ctx.alice_scope, ctx.message.uuid) end)
    refute carried?(queries)

    {_, queries} = traced(fn -> Messages.list_thread(ctx.message.thread_uuid) end)
    refute carried?(queries)
  end

  test "the send itself still reads the whole row", ctx do
    assert %Message{metadata: %{"html_body" => html}} = Repo.get!(Message, ctx.message.uuid)
    assert String.contains?(html, @marker)
  end
end
