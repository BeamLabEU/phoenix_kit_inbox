defmodule PhoenixKitInbox.Errors do
  @moduledoc """
  Central mapping from the error atoms this module's contexts return to
  translated, user-facing strings.

  Contexts return atoms (`{:error, :mailbox_access_denied}`); LiveViews call
  `message/1` at the flash boundary. Keeping the copy here means every "not
  found" reads identically across the three LiveViews, and translators have one
  file to work from.

  ## Example

      iex> PhoenixKitInbox.Errors.message(:message_not_found)
      "Message not found."
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  @doc "Translates an error reason into a user-facing string."
  @spec message(term()) :: String.t()
  def message(:mailbox_not_found), do: gettext("Mailbox not found.")
  def message(:message_not_found), do: gettext("Message not found.")
  def message(:recipient_not_found), do: gettext("Recipient not found.")
  def message(:no_recipients), do: gettext("Add at least one recipient.")
  def message(:invalid_user), do: gettext("Could not identify the current user.")

  def message(:mailbox_access_denied),
    do: gettext("You don't have access to this mailbox.")

  def message(:cannot_archive_personal_mailbox),
    do: gettext("Personal mailboxes can't be archived.")

  def message({:unknown_recipients, recipients}) do
    gettext("No mailbox matches: %{recipients}", recipients: Enum.join(recipients, ", "))
  end

  def message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field} #{Enum.join(messages, ", ")}"
    end)
  end

  def message(reason) when is_binary(reason), do: reason

  def message(reason) do
    gettext("Unexpected error: %{reason}", reason: inspect(reason))
  end
end
