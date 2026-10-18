if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.RestoreSoftDeletedTest do
    @moduledoc """
    `Bonfire.Common.Repo.Delete.restore_soft_deleted/2` restores whatever `soft_delete/1` deleted, whichever way it was deleted. A category is a Needle pointable, so soft-deleting it through its pointer makes Needle's trigger delete its row: its own fields are lost, while its mixins, which hang off the pointer, survive, and the row is recreated from the fields given. A post is a virtual, whose record is its pointer. And a media keeps a `deleted_at` column of its own. Here because it needs a pointable, which `bonfire_common` has none of.
    """
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils
    use Bonfire.Common.Repo

    @moduletag :backend

    alias Bonfire.Me.Fake
    alias Bonfire.Classify.Category
    alias Bonfire.Classify.Categories
    alias Bonfire.Common.Repo.Delete

    test "restore_soft_deleted recreates a pointable's row, which a soft delete of its pointer removed, keeping its mixins" do
      creator = Fake.fake_user!()
      group = fake_group!(creator)

      assert {:ok, %{profile: %{name: name}}} =
               Categories.get(id(group), skip_boundary_check: true, preload: :profile)

      assert {:ok, pointer} = Bonfire.Common.Needles.one(id(group), skip_boundary_check: true)
      assert {:ok, _} = Delete.soft_delete(pointer)

      refute repo().get(Category, id(group)),
             "control: marking the pointer deleted makes Needle delete the row"

      assert repo().get(Bonfire.Data.Social.Profile, id(group)),
             "control: the profile mixin hangs off the pointer, so it survives"

      assert {:ok, %Category{type: :group}} =
               Delete.restore_soft_deleted({Category, id(group)}, %{type: :group})

      assert {:ok, restored} =
               Categories.get(id(group), skip_boundary_check: true, preload: :profile)

      assert restored.type == :group
      assert restored.profile.name == name, "the mixins come back with it"
    end

    # a virtual's record is its pointer, so there is nothing to recreate: inserting one would fail
    test "restore_soft_deleted brings back a virtual by its pointer alone" do
      user = Fake.fake_user!()

      assert {:ok, post} =
               Bonfire.Posts.publish(
                 current_user: user,
                 post_attrs: %{post_content: %{html_body: "<p>back again</p>"}},
                 boundary: "public"
               )

      assert {:ok, _} = Delete.soft_delete(post)

      refute repo().get(Bonfire.Data.Social.Post, id(post)),
             "control: a virtual's view leaves out a deleted pointer"

      assert {:ok, %Bonfire.Data.Social.Post{}} =
               Delete.restore_soft_deleted({Bonfire.Data.Social.Post, id(post)})

      assert repo().get(Bonfire.Data.Social.Post, id(post))
    end

    # a schema with a `deleted_at` of its own is soft-deleted through that, its pointer untouched (media, which keeps its row)
    test "restore_soft_deleted clears a schema's own deleted_at when that is what was set" do
      user = Fake.fake_user!()
      media = Bonfire.Social.Fake.upload_media(:images, user)

      assert {:ok, _} = Delete.soft_delete(media)

      assert %{deleted_at: %DateTime{}} = repo().get(Bonfire.Files.Media, id(media)),
             "control: the media's own column was set, and its row kept"

      assert {:ok, %Bonfire.Files.Media{deleted_at: nil}} =
               Delete.restore_soft_deleted({Bonfire.Files.Media, id(media)})
    end
  end
end
