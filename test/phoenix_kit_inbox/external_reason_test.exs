defmodule PhoenixKitInbox.ExternalReasonTest do
  use ExUnit.Case, async: true

  alias PhoenixKitInbox.Errors
  alias PhoenixKitInbox.ExternalReason
  alias PhoenixKitInbox.Gettext, as: Backend

  # What `External` stores in the row's `error`.
  defp stored(reason), do: inspect(reason, limit: 20, printable_limit: 500)

  defp label(reason, locale \\ "en"),
    do:
      Gettext.with_locale(Backend, locale, fn -> reason |> stored() |> ExternalReason.label() end)

  describe "label/1 reads the stored text back into words" do
    test "the reasons the module's own errors already name" do
      assert label(:external_disabled) == Errors.message(:external_disabled)
      assert label({:filter_refused, :no_test_address}) == Errors.message({:filter_refused, nil})
      assert label(:filter_failed) == Errors.message(:filter_failed)
      assert label(:no_integration) == Errors.message(:no_integration)
      assert label(:mailbox_archived) == Errors.message(:mailbox_archived)

      assert label({:attachment_unavailable, Ecto.UUID.generate()}) ==
               Errors.message({:attachment_unavailable, nil})

      assert label({:external_too_large, 1_000_000}) ==
               Errors.message({:external_too_large, 1_000_000})

      assert label({:identity_unusable, :broken}) == Errors.message({:identity_unusable, :broken})

      assert label({:identity_unusable, :owner_gone}) ==
               Errors.message({:identity_unusable, :other})
    end

    test "the reasons that have words of their own" do
      assert label(:no_recipients) == "No recipient was left to send to."
      assert label(:not_started) == "The send could not be started."
      assert label(:forbidden) == "The sender is no longer allowed to send this email."
      assert label(:no_identity) == "The sender has no email address to send from."
      assert label({:transport_failed, "boom"}) == "The mail server did not take the email."
      assert label({:transport_exited, :exit}) == "The mail server did not take the email."
      assert label({:build_failed, "bad"}) == "The email could not be built."
    end

    test "anything else, and no reason at all, is plain \"Sending failed.\"" do
      assert label({:smtp, "550 rejected"}) == "Sending failed."
      assert label(:smtp_down) == "Sending failed."
      assert label(%{some: "map"}) == "Sending failed."
      assert ExternalReason.label(nil) == "Sending failed."
      assert ExternalReason.label("") == "Sending failed."
      # The stored text is cut at 500 characters: a cut tuple is not a reason.
      assert ExternalReason.label("{:transport_failed, \"" <> String.duplicate("x", 40)) ==
               "Sending failed."
    end

    test "an unknown atom is not turned into an atom" do
      name = "no_such_reason_#{System.unique_integer([:positive])}"

      assert ExternalReason.label(":" <> name) == "Sending failed."
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "speaks the locale of the process" do
      assert label(:not_started, "ru") == "Отправку не удалось запустить."
      assert label(:not_started, "et") == "Saatmist ei õnnestunud käivitada."
      assert label(:smtp_down, "ru") == "Не удалось отправить."
    end
  end

  test "known?/1 tells a known reason from the plain one" do
    assert ExternalReason.known?(stored(:external_disabled))
    assert ExternalReason.known?(stored({:transport_failed, "x"}))
    refute ExternalReason.known?(stored({:smtp, "550"}))
    refute ExternalReason.known?(nil)
  end
end
