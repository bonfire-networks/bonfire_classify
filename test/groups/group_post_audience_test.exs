defmodule Bonfire.Classify.GroupPostAudienceTest do
  use Bonfire.Classify.DataCase, async: false
  import Bonfire.Me.Fake

  alias Bonfire.Classify.Boundaries
  alias Bonfire.Classify.Categories

  test "private group and topic posts can narrow to moderators without admitting members" do
    owner = fake_user!()
    author = fake_user!()
    member = fake_user!()
    group = fake_group!(owner, %{visibility: "members:private", default_content_visibility: "members:private"})
    {:ok, _} = Categories.add_member(owner, group, author.id)
    {:ok, _} = Categories.add_member(owner, group, member.id)
    topic = fake_category!(owner, group, %{type: :topic, name: "Discussion #{Faker.Lorem.word()}"})

    assert Boundaries.list_post_audiences(group) == ["members:private", "moderators"]
    for destination <- [group, topic] do
      {:ok, post} = Bonfire.Posts.publish(current_user: author,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
        publish_in: destination.id, boundary: "moderators")
      assert Bonfire.Boundaries.can?(owner, :read, post)
      assert Bonfire.Boundaries.can?(author, :read, post)
      refute Bonfire.Boundaries.can?(member, :read, post)
      refute Bonfire.Boundaries.can?(:guest, :read, post)
      {:ok, reply} = Bonfire.Posts.publish(current_user: owner,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: post.id},
        boundary: "public")
      assert Bonfire.Boundaries.can?(author, :read, reply)
      refute Bonfire.Boundaries.can?(member, :read, reply)
      refute Bonfire.Boundaries.can?(:guest, :read, reply)
    end
  end

  test "a public override cannot escape a private group" do
    owner = fake_user!()
    outsider = fake_user!()
    group = fake_group!(owner, %{visibility: "members:private", default_content_visibility: "members:private"})
    {:ok, post} = Bonfire.Posts.publish(current_user: owner,
      post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
      publish_in: group.id, boundary: "public")
    refute Bonfire.Boundaries.can?(outsider, :read, post)
    refute Bonfire.Boundaries.can?(:guest, :read, post)
  end

  test "a group that cannot be resolved for the poster fails closed instead of dropping its ceiling" do
    owner = fake_user!()
    outsider = fake_user!()
    group = fake_group!(owner, %{visibility: "members:private", default_content_visibility: "members:private"})
    options = Boundaries.post_boundary_options(%Needle.Pointer{id: group.id}, [current_user: outsider, boundary: "public"], nil)
    assert options[:boundary] == "private"
    assert options[:to_circles] == []
  end

  test "a topic whose parent group is already loaded without settings still reads the group's default" do
    owner = fake_user!()
    group = fake_group!(owner, %{visibility: "members:private", default_content_visibility: "members:private"})
    topic = fake_category!(owner, group, %{type: :topic, name: "Inherits #{Faker.Lorem.word()}"})
    # as a page assigns it: parent preloaded, but not the parent's settings
    topic = topic |> Map.put(:parent_category, nil) |> Bonfire.Common.Repo.preload(:parent_category, force: true)
    assert Boundaries.read_default_content_visibility(topic) == "members:private"
  end

  test "local groups offer local visibility rather than public" do
    owner = fake_user!()
    group = fake_group!(owner, %{visibility: "local", default_content_visibility: "local"})
    assert Boundaries.list_post_audiences(group) == ["local", "members:private", "moderators"]
    {:ok, post} = Bonfire.Posts.publish(current_user: owner,
      post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
      publish_in: group.id, boundary: "public")
    assert Bonfire.Boundaries.can?(fake_user!(), :read, post)
    refute Bonfire.Boundaries.can?(:guest, :read, post)
  end

  test "public groups allow public posts and narrowing to members" do
    owner = fake_user!()
    group = fake_group!(owner, %{visibility: "global", default_content_visibility: "public"})
    assert Boundaries.list_post_audiences(group) == ["public", "members:private", "moderators"]
    for audience <- ["public", "members:private"] do
      {:ok, post} = Bonfire.Posts.publish(current_user: owner,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
        publish_in: group.id, boundary: audience)
      assert Bonfire.Boundaries.can?(:guest, :read, post) == (audience == "public")
    end
  end

  test "a narrower configured default remains the first choice" do
    for visibility <- ["global", "nonfederated"] do
      group = fake_group!(fake_user!(), %{visibility: visibility, default_content_visibility: "local"})
      assert List.first(Boundaries.list_post_audiences(group)) == "local"
    end
  end
  test "reply audiences narrow without admitting other members" do
    owner = fake_user!()
    author = fake_user!()
    member = fake_user!()
    group = fake_group!(owner, %{visibility: "members:private", default_content_visibility: "members:private"})
    {:ok, _} = Categories.add_member(owner, group, author.id)
    {:ok, _} = Categories.add_member(owner, group, member.id)
    {:ok, post} = Bonfire.Posts.publish(current_user: author,
      post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
      publish_in: group.id, boundary: "members:private")
    assert "reply_moderators" in Boundaries.list_reply_audiences(group, post)
    {:ok, reply} = Bonfire.Posts.publish(current_user: author,
      post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: post.id},
      boundary: "reply_moderators")
    assert Bonfire.Boundaries.can?(owner, :read, reply)
    assert Bonfire.Boundaries.can?(author, :read, reply)
    refute Bonfire.Boundaries.can?(member, :read, reply)
    refute Bonfire.Boundaries.can?(:guest, :read, reply)
    refute "reply_members" in Boundaries.list_reply_audiences(group, reply)
    {:ok, nested} = Bonfire.Posts.publish(current_user: owner,
      post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: reply.id},
      boundary: "reply_members")
    refute Bonfire.Boundaries.can?(member, :read, nested)
  end

  test "personal replies can narrow to the original author and reject broader nested audiences" do
    author = fake_user!()
    replier = fake_user!()
    other = fake_user!()
    {:ok, post} = Bonfire.Posts.publish(current_user: author,
      post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}}, boundary: "public")
    {:ok, reply} = Bonfire.Posts.publish(current_user: replier,
      post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: post.id},
      boundary: "reply_participants")
    assert Bonfire.Boundaries.can?(author, :read, reply)
    assert Bonfire.Boundaries.can?(replier, :read, reply)
    refute Bonfire.Boundaries.can?(other, :read, reply)
    refute Bonfire.Boundaries.can?(:guest, :read, reply)
    {:ok, nested} = Bonfire.Posts.publish(current_user: author,
      post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: reply.id},
      boundary: "public")
    assert Bonfire.Boundaries.can?(replier, :read, nested)
    refute Bonfire.Boundaries.can?(other, :read, nested)
  end

  test "public group replies narrow to members and preserve denials from a mixed parent ACL" do
    owner = fake_user!()
    member = fake_user!()
    excluded = fake_user!()
    group = fake_group!(owner, %{visibility: "global", default_content_visibility: "public"})
    {:ok, _} = Categories.add_member(owner, group, member.id)
    {:ok, _} = Categories.add_member(owner, group, excluded.id)
    {:ok, post} = Bonfire.Posts.publish(current_user: owner,
      post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}}, publish_in: group.id, boundary: "public")
    {:ok, acl} = Bonfire.Boundaries.Acls.create(%{named: %{name: Faker.Lorem.word()}}, current_user: owner)
    {:ok, _} = Bonfire.Boundaries.Grants.grant(member.id, acl.id, :read, true)
    {:ok, _} = Bonfire.Boundaries.Grants.grant(excluded.id, acl.id, :read, false)
    Bonfire.Boundaries.Controlleds.add_acls(post, acl)
    assert Bonfire.Boundaries.can?(member, :read, post)
    refute Bonfire.Boundaries.can?(excluded, :read, post)
    assert "reply_members" in Boundaries.list_reply_audiences(group, post)
    {:ok, reply} = Bonfire.Posts.publish(current_user: member,
      post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: post.id},
      boundary: "reply_members")
    assert Bonfire.Boundaries.can?(owner, :read, reply)
    assert Bonfire.Boundaries.can?(member, :read, reply)
    refute Bonfire.Boundaries.can?(excluded, :read, reply)
    refute Bonfire.Boundaries.can?(:guest, :read, reply)
  end

  test "inherited replies preserve the original author's blocked audience" do
    author = fake_user!()
    replier = fake_user!()
    excluded = fake_user!()
    {:ok, _} = Bonfire.Boundaries.Blocks.block(excluded, :ghost, current_user: author)
    {:ok, post} = Bonfire.Posts.publish(current_user: author,
      post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}}, boundary: "public")
    refute Bonfire.Boundaries.can?(excluded, :read, post)
    {:ok, reply} = Bonfire.Posts.publish(current_user: replier,
      post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: post.id},
      boundary: "clone_context", context_id: post.id)
    assert Bonfire.Boundaries.can?(author, :read, reply)
    assert Bonfire.Boundaries.can?(replier, :read, reply)
    refute Bonfire.Boundaries.can?(excluded, :read, reply)
  end

  test "addressed replies requested outside the composer are not widened to the public parent" do
    author = fake_user!()
    replier = fake_user!()
    mentioned = fake_user!()
    recipient = fake_user!()
    other = fake_user!()
    {:ok, post} = Bonfire.Posts.publish(current_user: author,
      post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}}, boundary: "public")

    # e.g. a Mastodon API "direct" reply, which arrives as the `mentions` preset
    {:ok, mentions_reply} = Bonfire.Posts.publish(current_user: replier,
      post_attrs: %{post_content: %{html_body: "@#{mentioned.character.username} #{Faker.Lorem.sentence()}"},
        reply_to_id: post.id},
      boundary: "mentions")
    assert Bonfire.Boundaries.can?(mentioned, :read, mentions_reply)
    refute Bonfire.Boundaries.can?(other, :read, mentions_reply)
    refute Bonfire.Boundaries.can?(:guest, :read, mentions_reply)

    {:ok, private_reply} = Bonfire.Posts.publish(current_user: replier,
      post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: post.id},
      boundary: "private", to_circles: [recipient.id])
    assert Bonfire.Boundaries.can?(recipient, :read, private_reply)
    refute Bonfire.Boundaries.can?(other, :read, private_reply)
    refute Bonfire.Boundaries.can?(:guest, :read, private_reply)
  end

  test "addressed replies still exclude people the parent's author blocked" do
    author = fake_user!()
    replier = fake_user!()
    excluded = fake_user!()
    {:ok, _} = Bonfire.Boundaries.Blocks.block(excluded, :ghost, current_user: author)
    {:ok, post} = Bonfire.Posts.publish(current_user: author,
      post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}}, boundary: "public")
    refute Bonfire.Boundaries.can?(excluded, :read, post)
    {:ok, reply} = Bonfire.Posts.publish(current_user: replier,
      post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: post.id},
      boundary: "private", to_circles: [excluded.id])
    assert Bonfire.Boundaries.can?(replier, :read, reply)
    refute Bonfire.Boundaries.can?(excluded, :read, reply)
  end

  test "direct message replies keep their recipients and remain private" do
    author = fake_user!()
    recipient = fake_user!()
    outsider = fake_user!()
    {:ok, message} = Bonfire.Messages.send(author,
      %{post_content: %{html_body: Faker.Lorem.sentence()}}, recipient)
    {:ok, reply} = Bonfire.Messages.send(recipient,
      %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: message.id}, author)
    assert Bonfire.Boundaries.can?(author, :read, reply)
    assert Bonfire.Boundaries.can?(recipient, :read, reply)
    refute Bonfire.Boundaries.can?(outsider, :read, reply)
    refute Bonfire.Boundaries.can?(:guest, :read, reply)
  end

end
