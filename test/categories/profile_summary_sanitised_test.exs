if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.ProfileSummarySanitisedTest do
    @moduledoc """
    The summary of a group or topic is shown as HTML, so it is sanitised when stored, whether the group is ours or a remote one's mirror.
    """
    use Bonfire.Classify.DataCase, async: true

    @moduletag :backend

    alias Bonfire.Classify.Category

    @payload "<p>About us</p><img src=x onerror=alert(1)><script>alert(2)</script>"

    for {kind, local?} <- [local: true, remote: false] do
      test "a #{kind} group's hostile summary is sanitised in its changeset" do
        summary =
          %{profile: %{name: "A group", summary: @payload}}
          |> Category.base_create_changeset(unquote(local?))
          |> Ecto.Changeset.get_change(:profile)
          |> Ecto.Changeset.get_change(:summary)

        assert summary =~ "About us"
        refute summary =~ "onerror"
        refute summary =~ "<script"
      end
    end
  end
end
