if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupNarrowerCollectionTest do
    @moduledoc """
    A group lists its topics and subgroups in a `narrower` collection (SKOS's inverse of the `broader` each of them names, FEP-9b2b), so another instance can show what is in a group without having met each one.

    Every group declares it, whatever it holds, since a URL that appeared with the first topic would need an actor `Update` to announce. What it SERVES is only the children the fediverse may see: a hidden subgroup in a public group isn't listed.
    """
    use Bonfire.Classify.ConnCase, async: false
    use Bonfire.Common.Utils
    @moduletag :backend

    alias Bonfire.Classify.Categories

    @public %{
      membership: "open",
      visibility: "global",
      participation: "anyone",
      default_content_visibility: "public"
    }

    @hidden %{
      membership: "invite_only",
      visibility: "members:private",
      participation: "group_members",
      default_content_visibility: "members:private"
    }

    defp with_dims(category, creator, dims) do
      assert :ok = Bonfire.Classify.Boundaries.replace(category, creator, dims)
      {:ok, category} = Categories.get(id(category), skip_boundary_check: true)
      category
    end

    defp served_narrower(group) do
      conn =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/pub/collections/narrower/#{id(group)}")

      json_response(conn, 200)
    end

    # embedded first page if paged, else the items themselves
    defp items(served),
      do: get_in(served, ["first", "items"]) || served["items"] || served["orderedItems"] || []

    defp listed?(served, category),
      do: Enum.any?(items(served), &String.contains?(&1, id(category)))

    setup do
      creator = Bonfire.Me.Fake.fake_user!()
      group = creator |> fake_group!() |> with_dims(creator, @public)
      {:ok, creator: creator, group: group}
    end

    test "a group's actor points at its narrower collection; a topic's doesn't", %{
      creator: creator,
      group: group
    } do
      topic = fake_category!(creator, group, %{type: :topic})

      assert %{data: data} = Categories.format_actor(group)
      assert data["narrower"] == ActivityPub.Utils.collection_ap_id("narrower", id(group))

      assert %{data: topic_data} = Categories.format_actor(topic)
      refute Map.has_key?(topic_data, "narrower"), "nothing is filed under a topic"
    end

    test "the collection lists the group's topics and subgroups", %{
      creator: creator,
      group: group
    } do
      topic = fake_category!(creator, group, %{type: :topic})

      subgroup =
        creator |> fake_category!(group, %{type: :group}) |> with_dims(creator, @public)

      served = served_narrower(group)

      assert listed?(served, topic), "Got: #{inspect(served)}"
      assert listed?(served, subgroup), "Got: #{inspect(served)}"
    end

    # the pair of the test above: a subgroup the fediverse may not see is not listed, though the URI is declared all the same
    test "a hidden subgroup isn't listed", %{creator: creator, group: group} do
      shown = creator |> fake_category!(group, %{type: :group}) |> with_dims(creator, @public)
      hidden = creator |> fake_category!(group, %{type: :group}) |> with_dims(creator, @hidden)

      served = served_narrower(group)

      assert listed?(served, shown),
             "control: a public subgroup is listed. Got: #{inspect(served)}"

      refute listed?(served, hidden),
             "the wire must not say more than the web does. Got: #{inspect(served)}"
    end
  end
end
