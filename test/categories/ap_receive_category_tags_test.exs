if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.ApReceiveCategoryTagsTest do
    @moduledoc """
    The `Category` items in the `tag` of an incoming AS2 object (FEP-9b2b), matched to the local categories they point at. See `plans/events-categories.md`.
    """
    use Bonfire.Classify.DataCase, async: true
    use Bonfire.Common.Utils
    use Bonfire.Common.Repo

    alias Bonfire.Me.Fake
    alias Bonfire.Classify.Categories
    alias Bonfire.Classify.Category

    setup do
      # TEMP: until we work on group federation, as in `groups_test.exs`
      Process.put(:federating, false)

      creator = Fake.fake_user!()
      topic = fake_category!(creator, nil, %{type: :topic, name: "Jazz"})

      {:ok, creator: creator, topic: repo().maybe_preload(topic, :character)}
    end

    defp category_item(iri), do: %{"type" => "Category", "id" => iri}

    describe "ap_receive_category_tags/3 matches a local category by its AP id" do
      test "given the canonical URL the category federates under", %{
        creator: creator,
        topic: topic
      } do
        iri = Bonfire.Me.Characters.character_url(topic)

        assert [%Category{id: id}] =
                 Categories.ap_receive_category_tags([category_item(iri)], creator, [])

        assert id == topic.id
      end

      test "given the actor URL with the username", %{creator: creator, topic: topic} do
        iri = "#{ActivityPub.Utils.ap_base_url()}/actors/#{topic.character.username}"

        assert [%Category{id: id}] =
                 Categories.ap_receive_category_tags([category_item(iri)], creator, [])

        assert id == topic.id
      end

      test "given the URL with the ULID", %{creator: creator, topic: topic} do
        iri = "#{ActivityPub.Utils.ap_base_url()}/group/#{topic.id}"

        assert [%Category{id: id}] =
                 Categories.ap_receive_category_tags([category_item(iri)], creator, [])

        assert id == topic.id
      end
    end

    describe "ap_receive_category_tags/3 returns nothing for" do
      test "an IRI under our base URL that matches no local category", %{creator: creator} do
        iri = "#{ActivityPub.Utils.ap_base_url()}/actors/no_such_category_here"

        assert [] = Categories.ap_receive_category_tags([category_item(iri)], creator, [])
      end

      test "a remote IRI, as remote lookups come with the S2S steps", %{creator: creator} do
        assert [] =
                 Categories.ap_receive_category_tags(
                   [category_item("https://other.example/category/jazz")],
                   creator,
                   []
                 )
      end

      test "items that are not Categories, even when they point at a local one", %{
        creator: creator,
        topic: topic
      } do
        iri = Bonfire.Me.Characters.character_url(topic)

        tags = [
          %{"type" => "Hashtag", "name" => "#jazz", "href" => iri},
          %{"type" => "HashTag", "name" => "#jazz", "href" => iri},
          %{"type" => "Mention", "name" => "@jazz", "href" => iri},
          %{"type" => "Mention", "id" => iri}
        ]

        assert [] = Categories.ap_receive_category_tags(tags, creator, [])
      end

      test "no tags at all", %{creator: creator} do
        assert [] = Categories.ap_receive_category_tags(nil, creator, [])
        assert [] = Categories.ap_receive_category_tags([], creator, [])
      end
    end
  end
end
