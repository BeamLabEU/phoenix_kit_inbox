defmodule PhoenixKitInbox.PathsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Path helpers are pure string building over `PhoenixKit.Utils.Routes.path/1`.
  The test_helper pins the URL prefix to `"/"`, and admin paths always carry
  the default locale, so the expected base here is `/en/admin/inbox`.
  """

  alias PhoenixKitInbox.Paths

  test "inbox/0 is the bare mailbox path" do
    assert Paths.inbox() =~ "/admin/inbox"
    refute Paths.inbox() =~ "?"
  end

  test "folder and message are query params, not path segments" do
    path = Paths.inbox(folder: "sent", message: "abc")

    assert path =~ "folder=sent"
    assert path =~ "message=abc"
    assert path =~ "/admin/inbox?"
  end

  test "nil and empty options are dropped rather than emitted as blanks" do
    path = Paths.inbox(folder: "drafts", message: nil, mailbox: "")

    assert path =~ "folder=drafts"
    refute path =~ "message="
    refute path =~ "mailbox="
  end

  test "compose accepts reply/forward/draft prefills" do
    assert Paths.compose(reply_to: "m1") =~ "reply_to=m1"
    assert Paths.compose(forward: "m2") =~ "forward=m2"
    assert Paths.compose(draft: "m3") =~ "draft=m3"
    assert Paths.compose() =~ "/admin/inbox/compose"
  end

  test "mailboxes/0 points at the management page" do
    assert Paths.mailboxes() =~ "/admin/inbox/mailboxes"
  end

  test "raw_message_path is deliberately unprefixed for notification links" do
    path = Paths.raw_message_path("mb-1", "msg-1")

    assert String.starts_with?(path, "/admin/inbox?")
    assert path =~ "mailbox=mb-1"
    assert path =~ "message=msg-1"
  end
end
