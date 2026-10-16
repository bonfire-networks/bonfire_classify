if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupEdgesSeeOnlyTest do
    @moduledoc """
    Edges on a group someone can see but not read. Loading one edge asks for `:read` on its object, as every single load does, so a caller that only needs the edge to exist asks for `:see`. The dedupe lookups of bookmark, flag and pin are such callers: they find the subject's own edge after the insert hit the unique constraint.
    """
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils
    use Bonfire.Common.Repo

    @moduletag :backend

    alias Bonfire.Me.Fake
    alias Bonfire.Social.Bookmarks
    alias Bonfire.Social.Flags
    alias Bonfire.Social.Pins

    setup do
      # TEMP: until we work on group federation
      Process.put(:federating, false)

      owner = Fake.fake_user!()
      visitor = Fake.fake_user!()

      group =
        fake_group!(owner, %{
          membership: "on_request",
          visibility: "nonfederated:preview",
          default_content_visibility: "members:private"
        })

      assert Bonfire.Boundaries.can?(visitor, :see, group), "control: a preview group is seen"
      refute Bonfire.Boundaries.can?(visitor, :read, group), "control: but not read"

      %{owner: owner, visitor: visitor, group: group}
    end

    test "a single edge load asks for :read on its object, or :see when told", %{
      visitor: visitor,
      group: group
    } do
      assert {:ok, bookmark} = Bookmarks.bookmark(visitor, group)

      assert {:ok, %{id: found}} = Bookmarks.get(visitor, group, verbs: [:see])
      assert found == id(bookmark)

      assert {:error, :not_found} = Bookmarks.get(visitor, group)
    end

    test "bookmarking a see-only group again returns the existing bookmark", %{
      visitor: visitor,
      group: group
    } do
      assert {:ok, bookmark} = Bookmarks.bookmark(visitor, group)
      assert {:ok, again} = Bookmarks.bookmark(visitor, group)
      assert id(again) == id(bookmark)
    end

    test "flagging a see-only group again returns the existing flag", %{
      visitor: visitor,
      group: group
    } do
      assert {:ok, flag} = Flags.flag(visitor, group)
      assert {:ok, again} = Flags.flag(visitor, group)
      assert id(again) == id(flag)
    end

    test "pinning a see-only group again returns the existing pin", %{
      visitor: visitor,
      group: group
    } do
      assert {:ok, pin} = Pins.pin(visitor, group)
      assert {:ok, again} = Pins.pin(visitor, group)
      assert id(again) == id(pin)
    end
  end
end
