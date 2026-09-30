defmodule Bonfire.Classify.GroupPostAudienceTest do
  use Bonfire.Classify.DataCase, async: false
  use Bonfire.Common.Config
  import Bonfire.Me.Fake

  alias Bonfire.Classify.Boundaries
  alias Bonfire.Classify.Categories

  test "private group and topic posts can narrow to moderators without admitting members" do
    owner = fake_user!()
    author = fake_user!()
    member = fake_user!()

    group =
      fake_group!(owner, %{
        visibility: "members:private",
        default_content_visibility: "members:private"
      })

    {:ok, _} = Categories.add_member(owner, group, author.id)
    {:ok, _} = Categories.add_member(owner, group, member.id)

    topic =
      fake_category!(owner, group, %{type: :topic, name: "Discussion #{Faker.Lorem.word()}"})

    assert Boundaries.list_post_audiences(group) == ["members:private", "moderators"]

    for destination <- [group, topic] do
      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
          publish_in: destination.id,
          boundary: "moderators"
        )

      assert Bonfire.Boundaries.can?(owner, :read, post)
      assert Bonfire.Boundaries.can?(author, :read, post)
      refute Bonfire.Boundaries.can?(member, :read, post)
      refute Bonfire.Boundaries.can?(:guest, :read, post)

      {:ok, reply} =
        Bonfire.Posts.publish(
          current_user: owner,
          post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: post.id},
          boundary: "public"
        )

      assert Bonfire.Boundaries.can?(author, :read, reply)

      # a reply's chosen audience is kept even when broader than its parent's, through the group's caps: here `public` becomes `members:private`, since the group is hidden
      # refute Bonfire.Boundaries.can?(member, :read, reply)
      assert Bonfire.Boundaries.can?(member, :read, reply)
      refute Bonfire.Boundaries.can?(:guest, :read, reply)
    end
  end

  test "a public override cannot escape a private group" do
    owner = fake_user!()
    outsider = fake_user!()

    group =
      fake_group!(owner, %{
        visibility: "members:private",
        default_content_visibility: "members:private"
      })

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: owner,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
        publish_in: group.id,
        boundary: "public"
      )

    refute Bonfire.Boundaries.can?(outsider, :read, post)
    refute Bonfire.Boundaries.can?(:guest, :read, post)
  end

  # `context_id` is how the composer and `fake_post_in_group!` publish into a group: the group is where the post goes, not what it replies to, so it must not inherit the group's own ACLs as a reply would
  test "a post published with the group as its context gets the same boundaries as one published in it" do
    owner = fake_user!()
    author = fake_user!()

    group =
      fake_group!(owner, %{
        visibility: "members:private",
        default_content_visibility: "members:private"
      })

    {:ok, _} = Categories.add_member(owner, group, author.id)

    acl_ids = fn post ->
      post
      |> Bonfire.Boundaries.Controlleds.list_on_object()
      |> Enum.map(& &1.acl_id)
      |> Enum.sort()
    end

    publish = fn opts ->
      {:ok, post} =
        Bonfire.Posts.publish(
          [
            current_user: author,
            post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
            boundary: "members:private"
          ] ++ opts
        )

      post
    end

    assert acl_ids.(publish.(context_id: group.id)) == acl_ids.(publish.(publish_in: group.id))
  end

  test "a group that cannot be resolved for the poster fails closed instead of dropping its ceiling" do
    owner = fake_user!()
    outsider = fake_user!()

    group =
      fake_group!(owner, %{
        visibility: "members:private",
        default_content_visibility: "members:private"
      })

    options =
      Boundaries.post_boundary_options(
        %Needle.Pointer{id: group.id},
        [current_user: outsider, boundary: "public"],
        nil
      )

    assert options[:boundary] == "private"
    assert options[:to_circles] == []
    assert options[:verb_grants] == []
    assert options[:acl_ids] == []
  end

  # the reachable side of the same case: the Tag act only passes on groups the author may tag, so an outsider's post is simply not published in a group they can't load
  test "a post aimed at a hidden group by someone who can't see it doesn't land in the group, nor get its ACLs" do
    owner = fake_user!()
    outsider = fake_user!()

    group =
      fake_group!(owner, %{
        visibility: "members:private",
        default_content_visibility: "members:private"
      })

    {:ok, moderators_acl} = Bonfire.Boundaries.Scaffold.Groups.moderators_acl(group)
    {:ok, members_acl} = Bonfire.Boundaries.Scaffold.Groups.members_acl(group)

    tree_parent_id = fn post ->
      case Bonfire.Common.Repo.maybe_preload(post, :tree).tree do
        %{parent_id: parent_id} -> parent_id
        _ -> nil
      end
    end

    for route <- [:publish_in, :context_id] do
      publish = fn user ->
        {:ok, post} =
          Bonfire.Posts.publish([
            {route, group.id},
            current_user: user,
            post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
            boundary: "public"
          ])

        {post, post |> Bonfire.Boundaries.Controlleds.list_on_object() |> Enum.map(& &1.acl_id)}
      end

      # control: the same publish by someone who can see the group does land in it, with its ACLs
      {owner_post, owner_acl_ids} = publish.(owner)
      assert tree_parent_id.(owner_post) == group.id, "control: in the group, via #{route}"
      assert moderators_acl.id in owner_acl_ids, "control: moderators ACL, via #{route}"

      {post, acl_ids} = publish.(outsider)
      refute tree_parent_id.(post) == group.id, "not in the group, via #{route}"
      refute moderators_acl.id in acl_ids, "no moderators ACL, via #{route}"
      refute members_acl.id in acl_ids, "no members ACL, via #{route}"
    end
  end

  test "a topic whose parent group is already loaded without settings still reads the group's default" do
    owner = fake_user!()

    group =
      fake_group!(owner, %{
        visibility: "members:private",
        default_content_visibility: "members:private"
      })

    topic = fake_category!(owner, group, %{type: :topic, name: "Inherits #{Faker.Lorem.word()}"})
    # as a page assigns it: parent preloaded, but not the parent's settings
    topic =
      topic
      |> Map.put(:parent_category, nil)
      |> Bonfire.Common.Repo.preload(:parent_category, force: true)

    assert Boundaries.read_default_content_visibility(topic) == "members:private"
  end

  # `visibility: "local"` makes the group unfederated, so its federated posts stop federating; `default_content_visibility: "local"` is what a post gets with no audience chosen
  test "local groups offer local visibility rather than public" do
    owner = fake_user!()
    group = fake_group!(owner, %{visibility: "local", default_content_visibility: "local"})
    # assert Boundaries.list_post_audiences(group) == ["local", "members:private", "moderators"]
    assert Boundaries.list_post_audiences(group) == [
             "local",
             "nonfederated",
             "members:private",
             "moderators"
           ]

    {:ok, default_post} =
      Bonfire.Posts.publish(
        current_user: owner,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
        publish_in: group.id
      )

    assert Bonfire.Boundaries.can?(fake_user!(), :read, default_post)
    refute Bonfire.Boundaries.can?(:guest, :read, default_post)

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: owner,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
        publish_in: group.id,
        boundary: "public"
      )

    assert Bonfire.Boundaries.can?(fake_user!(), :read, post)

    # a `public` post in an unfederated group becomes `nonfederated`, which guests on this instance may read
    # refute Bonfire.Boundaries.can?(:guest, :read, post)
    {:ok, nonfederated} =
      Bonfire.Posts.publish(
        current_user: owner,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
        publish_in: group.id,
        boundary: "nonfederated"
      )

    assert post_acl_ids(post) == post_acl_ids(nonfederated)
  end

  test "public groups allow public posts and narrowing to members" do
    owner = fake_user!()
    group = fake_group!(owner, %{visibility: "global", default_content_visibility: "public"})
    assert Boundaries.list_post_audiences(group) == ["public", "members:private", "moderators"]

    for audience <- ["public", "members:private"] do
      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: owner,
          post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
          publish_in: group.id,
          boundary: audience
        )

      assert Bonfire.Boundaries.can?(:guest, :read, post) == (audience == "public")
    end
  end

  describe "a requested audience the group does not list" do
    # both ways a post is published into a group: `publish_in:` (API, federation) and `context_id:` (the composer)
    defp publish_via(route, user, group, opts) do
      {:ok, post} =
        Bonfire.Posts.publish(
          [
            {route, group.id},
            current_user: user,
            post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}}
          ] ++ opts
        )

      post
    end

    defp group_with_moderator(attrs) do
      owner = fake_user!()
      moderator = fake_user!()
      member = fake_user!()
      group = fake_group!(owner, attrs)
      {:ok, _} = Categories.add_moderator(owner, group, moderator.id)
      {:ok, _} = Categories.add_member(owner, group, member.id)
      %{owner: owner, moderator: moderator, member: member, group: group}
    end

    # the composer addresses the group itself (`post_circles_for_group/1`); its members and moderators get in through the ACLs that come with publishing in it (`acl_ids_for_published_in/1`), not by being addressed on each post
    test "in a members-only group, members and moderators read and reply to a post addressed to the group alone, and outsiders don't" do
      %{owner: owner, moderator: moderator, member: member, group: group} =
        group_with_moderator(%{
          visibility: "global",
          default_content_visibility: "members:private"
        })

      outsider = fake_user!()

      for route <- [:publish_in, :context_id] do
        post = publish_via(route, owner, group, to_circles: [group.id])

        for {who, name} <- [{member, "a member"}, {moderator, "a moderator"}] do
          assert Bonfire.Boundaries.can?(who, :read, post), "#{name} reads it, via #{route}"
          assert Bonfire.Boundaries.can?(who, :reply, post), "#{name} may reply, via #{route}"
        end

        refute Bonfire.Boundaries.can?(outsider, :read, post),
               "an outsider doesn't read it, via #{route}"

        refute Bonfire.Boundaries.can?(:guest, :read, post), "a guest doesn't, via #{route}"
      end
    end

    test "a group defaulting to its moderators: a post without a request is theirs, not its members'" do
      %{owner: owner, moderator: moderator, member: member, group: group} =
        group_with_moderator(%{visibility: "global", default_content_visibility: "moderators"})

      for route <- [:publish_in, :context_id] do
        post = publish_via(route, owner, group, [])

        assert Bonfire.Boundaries.can?(moderator, :read, post),
               "a moderator reads it, via #{route}"

        refute Bonfire.Boundaries.can?(member, :read, post), "a member doesn't, via #{route}"
      end
    end

    test "without a request, the group's default applies" do
      %{owner: owner, group: group} =
        group_with_moderator(%{visibility: "global", default_content_visibility: "public"})

      for route <- [:publish_in, :context_id] do
        assert Bonfire.Boundaries.can?(:guest, :read, publish_via(route, owner, group, [])),
               "via #{route}"
      end
    end

    test "narrower than the group allows: `private` stays with its author" do
      %{owner: owner, member: member, group: group} =
        group_with_moderator(%{visibility: "global", default_content_visibility: "public"})

      for route <- [:publish_in, :context_id] do
        post = publish_via(route, owner, group, boundary: "private")
        assert Bonfire.Boundaries.can?(owner, :read, post), "via #{route}"
        refute Bonfire.Boundaries.can?(member, :read, post), "via #{route}"
        refute Bonfire.Boundaries.can?(fake_user!(), :read, post), "via #{route}"
      end
    end

    test "narrower than the group allows: `public:preview` can be seen but not read by an outsider" do
      %{owner: owner, group: group} =
        group_with_moderator(%{visibility: "global", default_content_visibility: "public"})

      for route <- [:publish_in, :context_id] do
        post = publish_via(route, owner, group, boundary: "public:preview")
        outsider = fake_user!()
        assert Bonfire.Boundaries.can?(outsider, :see, post), "an outsider sees it, via #{route}"

        refute Bonfire.Boundaries.can?(outsider, :read, post),
               "an outsider does not read it, via #{route}"
      end
    end

    test "narrower than the group allows: `nonfederated:unlisted` can be read and replied to locally, but not boosted" do
      %{owner: owner, group: group} =
        group_with_moderator(%{visibility: "global", default_content_visibility: "public"})

      for route <- [:publish_in, :context_id] do
        post = publish_via(route, owner, group, boundary: "nonfederated:unlisted")
        other = fake_user!()
        assert Bonfire.Boundaries.can?(other, :read, post), "a local user reads it, via #{route}"

        assert Bonfire.Boundaries.can?(other, :reply, post),
               "a local user replies to it, via #{route}"

        refute Bonfire.Boundaries.can?(other, :boost, post),
               "a local user does not boost it, via #{route}"
      end
    end

    # replaced: a `public` post in a hidden group is now capped to `members:private`, so members read it too; covered by "every group visibility × chosen audience" (`visibility: members:private`)
    # # fail closed: only the group's moderators and the author, never the group's broader default
    @tag :skip
    test "wider than the group allows: closes to its moderators and the author" do
      %{owner: owner, moderator: moderator, member: member, group: group} =
        group_with_moderator(%{
          visibility: "members:private",
          default_content_visibility: "members:private"
        })

      for route <- [:publish_in, :context_id] do
        post = publish_via(route, owner, group, boundary: "public")
        assert Bonfire.Boundaries.can?(owner, :read, post), "via #{route}"
        assert Bonfire.Boundaries.can?(moderator, :read, post), "via #{route}"
        refute Bonfire.Boundaries.can?(member, :read, post), "via #{route}"
        refute Bonfire.Boundaries.can?(:guest, :read, post), "via #{route}"
      end
    end

    # replaced: an unrecognised audience now gets the group's default (stored, or else derived from its visibility); covered by "every group visibility × chosen audience" and the no-stored-default tests, and failing closed by the test for a group whose stored default is unrecognised too
    @tag :skip
    test "not recognised: closes to its moderators and the author" do
      %{owner: owner, moderator: moderator, member: member, group: group} =
        group_with_moderator(%{visibility: "global", default_content_visibility: "public"})

      for route <- [:publish_in, :context_id] do
        post = publish_via(route, owner, group, boundary: "no_such_audience")
        assert Bonfire.Boundaries.can?(owner, :read, post), "via #{route}"
        assert Bonfire.Boundaries.can?(moderator, :read, post), "via #{route}"
        refute Bonfire.Boundaries.can?(member, :read, post), "via #{route}"
        refute Bonfire.Boundaries.can?(:guest, :read, post), "via #{route}"
      end
    end
  end

  test "a narrower configured default remains the first choice" do
    for visibility <- ["global", "nonfederated"] do
      group =
        fake_group!(fake_user!(), %{visibility: visibility, default_content_visibility: "local"})

      assert List.first(Boundaries.list_post_audiences(group)) == "local"
    end
  end

  test "a group reply limited to its moderators keeps members out, and a reply to it keeps the audience its author chose, or with none chosen gets its parent's" do
    owner = fake_user!()
    author = fake_user!()
    member = fake_user!()

    group =
      fake_group!(owner, %{
        visibility: "members:private",
        default_content_visibility: "members:private"
      })

    {:ok, _} = Categories.add_member(owner, group, author.id)
    {:ok, _} = Categories.add_member(owner, group, member.id)

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
        publish_in: group.id,
        boundary: "members:private"
      )

    assert "reply_moderators" in Boundaries.list_reply_audiences(group, post)

    {:ok, reply} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: post.id},
        boundary: "reply_moderators"
      )

    assert Bonfire.Boundaries.can?(owner, :read, reply)
    assert Bonfire.Boundaries.can?(author, :read, reply)
    refute Bonfire.Boundaries.can?(member, :read, reply)
    refute Bonfire.Boundaries.can?(:guest, :read, reply)
    refute "reply_members" in Boundaries.list_reply_audiences(group, reply)

    {:ok, nested} =
      Bonfire.Posts.publish(
        current_user: owner,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: reply.id},
        boundary: "reply_members"
      )

    # a reply's chosen audience is kept even when broader than its parent's (the UI defaults to the parent's, but doesn't stop anyone opening up); members are within this hidden group's cap
    # refute Bonfire.Boundaries.can?(member, :read, nested)
    assert Bonfire.Boundaries.can?(member, :read, nested)
    refute Bonfire.Boundaries.can?(:guest, :read, nested)

    {:ok, nested_by_default} =
      Bonfire.Posts.publish(
        current_user: owner,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: reply.id}
      )

    assert Bonfire.Boundaries.can?(author, :read, nested_by_default)

    refute Bonfire.Boundaries.can?(member, :read, nested_by_default),
           "with no audience chosen, it's its parent's, moderators only"
  end

  # a reply in a group keeps the audience its author chose, through the group's caps; the parent's blocks still apply
  describe "a group reply's chosen audience" do
    defp group_post!(author, group, boundary) do
      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
          publish_in: group.id,
          boundary: boundary
        )

      post
    end

    defp group_reply!(author, parent, opts) do
      {:ok, reply} =
        Bonfire.Posts.publish(
          [
            current_user: author,
            post_attrs: %{
              post_content: %{html_body: Faker.Lorem.sentence()},
              reply_to_id: parent.id
            }
          ] ++ opts
        )

      reply
    end

    test "is kept when broader than its parent's" do
      owner = fake_user!()
      group = fake_group!(owner, %{visibility: "global", default_content_visibility: "public"})
      parent = group_post!(owner, group, "members:private")
      refute Bonfire.Boundaries.can?(:guest, :read, parent), "control: the parent is members only"

      assert Bonfire.Boundaries.can?(
               :guest,
               :read,
               group_reply!(owner, parent, boundary: "public")
             )
    end

    test "is capped in a hidden group" do
      owner = fake_user!()
      member = fake_user!()

      group =
        fake_group!(owner, %{
          visibility: "members:private",
          default_content_visibility: "members:private"
        })

      {:ok, _} = Categories.add_member(owner, group, member.id)
      reply = group_reply!(owner, group_post!(owner, group, "moderators"), boundary: "public")
      assert Bonfire.Boundaries.can?(member, :read, reply), "a member reads it"
      refute Bonfire.Boundaries.can?(fake_user!(), :read, reply), "an outsider doesn't"
      refute Bonfire.Boundaries.can?(:guest, :read, reply), "a guest doesn't"
    end

    test "only a member may reply to a members-only post" do
      owner = fake_user!()
      member = fake_user!()
      outsider = fake_user!()
      group = fake_group!(owner, %{visibility: "global", default_content_visibility: "public"})
      {:ok, _} = Categories.add_member(owner, group, member.id)
      parent = group_post!(owner, group, "members:private")

      assert Bonfire.Boundaries.can?(member, :reply, parent), "control: a member may"
      assert %{} = group_reply!(member, parent, []), "control: a member's reply is published"

      refute Bonfire.Boundaries.can?(outsider, :reply, parent), "a non-member may not"

      # the refusal raises inside the publish epic's linked task, which would take this process down unless trapped
      Process.flag(:trap_exit, true)

      assert catch_exit(group_reply!(outsider, parent, [])),
             "a non-member's reply isn't published"
    end

    # a reply to the thread's opening post, just not marked as one (no `reply_to_id`, see `Bonfire.Social.ThreadWithoutReplyToTest`), so it gets that post's audience rather than the group's default
    test "a post in a group thread that replies to nothing gets the opening post's audience" do
      owner = fake_user!()
      group = fake_group!(owner, %{visibility: "global", default_content_visibility: "local"})
      thread = group_post!(owner, group, "public")
      assert Bonfire.Boundaries.can?(:guest, :read, thread), "control: the thread is public"

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: owner,
          post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, thread_id: thread.id},
          context_id: thread.id,
          to_boundaries: ["clone_context"]
        )

      assert Bonfire.Boundaries.can?(:guest, :read, post),
             "a guest reads it: the opening post's `public`, not the group's `local`"
    end

    test "still excludes people the parent's author blocked" do
      owner = fake_user!()
      excluded = fake_user!()
      {:ok, _} = Bonfire.Boundaries.Blocks.block(excluded, :ghost, current_user: owner)
      group = fake_group!(owner, %{visibility: "global", default_content_visibility: "public"})
      # a member, since only they may reply to a members-only post
      replier = fake_user!()
      {:ok, _} = Categories.add_member(owner, group, replier.id)

      reply =
        group_reply!(replier, group_post!(owner, group, "members:private"), boundary: "public")

      assert Bonfire.Boundaries.can?(:guest, :read, reply), "control: the reply is public"
      refute Bonfire.Boundaries.can?(excluded, :read, reply), "the blocked person doesn't read it"
    end
  end

  test "a reply limited to the original author + the replier is readable by just them, and a reply to it keeps the audience its author chose, but if the author chooses no audience, it gets its parent's audience" do
    author = fake_user!()
    replier = fake_user!()
    other = fake_user!()

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
        boundary: "public"
      )

    {:ok, reply} =
      Bonfire.Posts.publish(
        current_user: replier,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: post.id},
        boundary: "reply_participants"
      )

    assert Bonfire.Boundaries.can?(author, :read, reply)
    assert Bonfire.Boundaries.can?(replier, :read, reply)
    refute Bonfire.Boundaries.can?(other, :read, reply)
    refute Bonfire.Boundaries.can?(:guest, :read, reply)

    {:ok, nested} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: reply.id},
        boundary: "public"
      )

    assert Bonfire.Boundaries.can?(replier, :read, nested)

    # a reply's chosen audience is kept even when broader than its parent's (the UI defaults to the parent's, but doesn't stop anyone opening up)
    # refute Bonfire.Boundaries.can?(other, :read, nested)
    assert Bonfire.Boundaries.can?(other, :read, nested)

    # with no audience chosen, a reply gets its parent's, here limited to the two of them
    {:ok, nested_by_default} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: reply.id}
      )

    assert Bonfire.Boundaries.can?(replier, :read, nested_by_default)
    refute Bonfire.Boundaries.can?(other, :read, nested_by_default)
    refute Bonfire.Boundaries.can?(:guest, :read, nested_by_default)
  end

  test "public group replies narrow to members and preserve denials from a mixed parent ACL" do
    owner = fake_user!()
    member = fake_user!()
    excluded = fake_user!()
    group = fake_group!(owner, %{visibility: "global", default_content_visibility: "public"})
    {:ok, _} = Categories.add_member(owner, group, member.id)
    {:ok, _} = Categories.add_member(owner, group, excluded.id)

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: owner,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
        publish_in: group.id,
        boundary: "public"
      )

    {:ok, acl} =
      Bonfire.Boundaries.Acls.create(%{named: %{name: Faker.Lorem.word()}}, current_user: owner)

    {:ok, _} = Bonfire.Boundaries.Grants.grant(member.id, acl.id, :read, true)
    {:ok, _} = Bonfire.Boundaries.Grants.grant(excluded.id, acl.id, :read, false)
    Bonfire.Boundaries.Controlleds.add_acls(post, acl)
    assert Bonfire.Boundaries.can?(member, :read, post)
    refute Bonfire.Boundaries.can?(excluded, :read, post)
    assert "reply_members" in Boundaries.list_reply_audiences(group, post)

    {:ok, reply} =
      Bonfire.Posts.publish(
        current_user: member,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: post.id},
        boundary: "reply_members"
      )

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

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
        boundary: "public"
      )

    refute Bonfire.Boundaries.can?(excluded, :read, post)

    {:ok, reply} =
      Bonfire.Posts.publish(
        current_user: replier,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: post.id},
        boundary: "clone_context",
        context_id: post.id
      )

    assert Bonfire.Boundaries.can?(author, :read, reply)
    assert Bonfire.Boundaries.can?(replier, :read, reply)
    refute Bonfire.Boundaries.can?(excluded, :read, reply)
  end

  test "inherited replies follow the parent's mixed ACL, including when its denial is later lifted" do
    author = fake_user!()
    replier = fake_user!()
    excluded = fake_user!()

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
        boundary: "public"
      )

    {:ok, acl} =
      Bonfire.Boundaries.Acls.create(%{named: %{name: Faker.Lorem.word()}}, current_user: author)

    {:ok, _} = Bonfire.Boundaries.Grants.grant(replier.id, acl.id, :read, true)
    {:ok, _} = Bonfire.Boundaries.Grants.grant(excluded.id, acl.id, :read, false)
    Bonfire.Boundaries.Controlleds.add_acls(post, acl)
    refute Bonfire.Boundaries.can?(excluded, :read, post)

    {:ok, reply} =
      Bonfire.Posts.publish(
        current_user: replier,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: post.id},
        boundary: "clone_context",
        context_id: post.id
      )

    refute Bonfire.Boundaries.can?(excluded, :read, reply)

    # the reply shares the parent's ACL rather than a copy of its denial, so lifting it applies to both
    Bonfire.Boundaries.Grants.grant(excluded.id, acl.id, :read, nil)
    assert Bonfire.Boundaries.can?(excluded, :read, post)
    assert Bonfire.Boundaries.can?(excluded, :read, reply)
  end

  test "addressed replies requested outside the composer are not widened to the public parent" do
    author = fake_user!()
    replier = fake_user!()
    mentioned = fake_user!()
    recipient = fake_user!()
    other = fake_user!()

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
        boundary: "public"
      )

    # e.g. a Mastodon API "direct" reply, which arrives as the `mentions` preset
    {:ok, mentions_reply} =
      Bonfire.Posts.publish(
        current_user: replier,
        post_attrs: %{
          post_content: %{html_body: "@#{mentioned.character.username} #{Faker.Lorem.sentence()}"},
          reply_to_id: post.id
        },
        boundary: "mentions"
      )

    assert Bonfire.Boundaries.can?(mentioned, :read, mentions_reply)
    refute Bonfire.Boundaries.can?(other, :read, mentions_reply)
    refute Bonfire.Boundaries.can?(:guest, :read, mentions_reply)

    {:ok, private_reply} =
      Bonfire.Posts.publish(
        current_user: replier,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: post.id},
        boundary: "private",
        to_circles: [recipient.id]
      )

    assert Bonfire.Boundaries.can?(recipient, :read, private_reply)
    refute Bonfire.Boundaries.can?(other, :read, private_reply)
    refute Bonfire.Boundaries.can?(:guest, :read, private_reply)
  end

  test "addressed replies still exclude people the parent's author blocked" do
    author = fake_user!()
    replier = fake_user!()
    excluded = fake_user!()
    {:ok, _} = Bonfire.Boundaries.Blocks.block(excluded, :ghost, current_user: author)

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}},
        boundary: "public"
      )

    refute Bonfire.Boundaries.can?(excluded, :read, post)

    {:ok, reply} =
      Bonfire.Posts.publish(
        current_user: replier,
        post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: post.id},
        boundary: "private",
        to_circles: [excluded.id]
      )

    assert Bonfire.Boundaries.can?(replier, :read, reply)
    refute Bonfire.Boundaries.can?(excluded, :read, reply)
  end

  test "direct message replies keep their recipients and remain private" do
    author = fake_user!()
    recipient = fake_user!()
    outsider = fake_user!()

    {:ok, message} =
      Bonfire.Messages.send(
        author,
        %{post_content: %{html_body: Faker.Lorem.sentence()}},
        recipient
      )

    {:ok, reply} =
      Bonfire.Messages.send(
        recipient,
        %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: message.id},
        author
      )

    assert Bonfire.Boundaries.can?(author, :read, reply)
    assert Bonfire.Boundaries.can?(recipient, :read, reply)
    refute Bonfire.Boundaries.can?(outsider, :read, reply)
    refute Bonfire.Boundaries.can?(:guest, :read, reply)
  end

  # A group's `visibility` is who can see the GROUP, not its posts. So the audience chosen for a post is kept, except for two caps:
  # - an unfederated group (`visibility` scope not `global`) drops a federated post to `nonfederated`, keeping its role;
  # - a hidden group (`visibility: "members:private"`) caps its posts to `members:private`.
  # With no audience chosen, or an unrecognised one, the post gets the group's `default_content_visibility`, through the same caps.
  describe "every group visibility × chosen audience" do
    @post_audiences [
      "public",
      "public:preview",
      "unlisted",
      "nonfederated",
      "nonfederated:preview",
      "nonfederated:unlisted",
      "local",
      "local:preview",
      "local:unlisted",
      "members:private",
      "moderators",
      "private"
    ]
    # the group's `default_content_visibility`, federated so that the caps apply to it too
    @group_default "public"

    # written out by hand, not derived from the code under test
    defp expected_audience(visibility, chosen) when chosen in [nil, "no_such_audience"],
      do: expected_audience(visibility, @group_default)

    defp expected_audience("members:private", chosen) when chosen in ["moderators", "private"],
      do: chosen

    defp expected_audience("members:private", _chosen), do: "members:private"

    defp expected_audience(visibility, chosen)
         when visibility in ["global", "preview", "unlisted"], do: chosen

    defp expected_audience(_unfederated, chosen),
      do:
        Map.get(
          %{
            "public" => "nonfederated",
            "public:preview" => "nonfederated:preview",
            "unlisted" => "nonfederated:unlisted"
          },
          chosen,
          chosen
        )

    defp post_acl_ids(post),
      do:
        post
        |> Bonfire.Boundaries.Controlleds.list_on_object()
        |> Enum.map(& &1.acl_id)
        |> Enum.sort()

    # the reference post really has its expected audience, so two posts that both failed closed can't pass as equal
    defp assert_has_audience(acl_ids, "members:private", group) do
      {:ok, members_acl} = Bonfire.Boundaries.Scaffold.Groups.members_acl(group)
      assert members_acl.id in acl_ids, "a members:private post carries the group's members ACL"
    end

    defp assert_has_audience(acl_ids, narrowest, group)
         when narrowest in ["moderators", "private"] do
      {:ok, members_acl} = Bonfire.Boundaries.Scaffold.Groups.members_acl(group)

      refute members_acl.id in acl_ids,
             "a #{narrowest} post doesn't carry the group's members ACL"
    end

    defp assert_has_audience(acl_ids, audience, _group) do
      preset_acl_ids =
        Bonfire.Boundaries.Acls.preset_acl_ids(audience, Bonfire.Common.Config.get!(:preset_acls))

      assert preset_acl_ids != [] and Enum.all?(preset_acl_ids, &(&1 in acl_ids)),
             "a #{audience} post carries that preset's ACLs"
    end

    for visibility <- [
          "global",
          "preview",
          "unlisted",
          "nonfederated",
          "nonfederated:preview",
          "nonfederated:unlisted",
          "local",
          "local:preview",
          "local:unlisted",
          "members:private"
        ] do
      @visibility visibility
      test "in a group with `visibility: #{visibility}`, each chosen audience is kept or capped" do
        owner = fake_user!()

        group =
          fake_group!(owner, %{
            visibility: @visibility,
            default_content_visibility: @group_default
          })

        for route <- [:publish_in, :context_id],
            chosen <- [nil, "no_such_audience" | @post_audiences] do
          expected = expected_audience(@visibility, chosen)
          post = publish_via(route, owner, group, if(chosen, do: [boundary: chosen], else: []))
          reference = publish_via(route, owner, group, boundary: expected)
          assert_has_audience(post_acl_ids(reference), expected, group)

          assert post_acl_ids(post) == post_acl_ids(reference),
                 "#{inspect(chosen)} should become #{expected}, via #{route}"
        end
      end
    end

    # a group that states no default (eg. an older or mirrored one) gets the one derived from its visibility, as `resolve_dims/1` does at creation
    for {visibility, expected} <- [
          {"global", "public"},
          {"nonfederated", "nonfederated"},
          {"local", "local"},
          {"members:private", "members:private"}
        ] do
      @visibility visibility
      @expected expected
      test "with no audience chosen, a group with `visibility: #{visibility}` and no stored default gives its posts #{expected}" do
        owner = fake_user!()
        group = fake_group!(owner, %{visibility: @visibility})

        Bonfire.Common.Settings.put([:default_content_visibility], nil,
          scope: group,
          skip_boundary_check: true
        )

        group = Bonfire.Common.Repo.preload(group, :settings, force: true)

        assert is_nil(Boundaries.read_default_content_visibility(group)),
               "control: the group has no stored default"

        for route <- [:publish_in, :context_id] do
          reference = publish_via(route, owner, group, boundary: @expected)
          assert_has_audience(post_acl_ids(reference), @expected, group)

          assert post_acl_ids(publish_via(route, owner, group, [])) == post_acl_ids(reference),
                 "via #{route}"
        end
      end
    end

    # fail closed: only the group's moderators and the author
    test "an unrecognised audience in a group whose default is unrecognised too closes to its moderators and the author" do
      %{owner: owner, moderator: moderator, member: member, group: group} =
        group_with_moderator(%{
          visibility: "global",
          default_content_visibility: "no_such_default"
        })

      for route <- [:publish_in, :context_id] do
        post = publish_via(route, owner, group, boundary: "no_such_audience")
        assert Bonfire.Boundaries.can?(owner, :read, post), "the author reads it, via #{route}"

        assert Bonfire.Boundaries.can?(moderator, :read, post),
               "a moderator reads it, via #{route}"

        refute Bonfire.Boundaries.can?(member, :read, post),
               "a member does not read it, via #{route}"

        refute Bonfire.Boundaries.can?(:guest, :read, post),
               "a guest does not read it, via #{route}"
      end
    end
  end
end
