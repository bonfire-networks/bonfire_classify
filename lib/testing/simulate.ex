# check that this extension is configured
defmodule Bonfire.Classify.Simulate do
  import Bonfire.Common.Simulation
  use Bonfire.Common.Repo

  alias Bonfire.Classify.Categories

  ### Start fake data functions

  def category(base \\ %{}) do
    base
    # |> Map.put_new_lazy(:id, &uuid/0)
    |> Map.put_new_lazy(:name, &name/0)
    |> Map.put_new_lazy(:note, &summary/0)
    |> Map.put_new_lazy(:is_public, &truth/0)
    |> Map.put_new_lazy(:is_disabled, &falsehood/0)
  end

  def fake_category!(user, parent_category \\ nil, overrides \\ %{})

  def fake_category!(user, nil, overrides) do
    with {:ok, category} <- Categories.create(user, category(overrides)) do
      category
    else
      {:error, %Ecto.Changeset{errors: [{:username, _} | _]}} ->
        fake_category!(user, nil, overrides)

      other ->
        raise "fake_category! failed: #{inspect(other)}"
    end
  end

  def fake_category!(user, parent_category, overrides) do
    {:ok, category} =
      Categories.create(
        user,
        category(Map.put(overrides, :parent_category, parent_category))
      )

    category
  end

  def fake_group!(creator, overrides \\ %{}) do
    fake_category!(
      creator,
      nil,
      Map.merge(%{type: :group}, overrides)
    )
    |> repo().maybe_preload(:settings)
  end

  @doc """
  A category plus the identifiers a federation test needs to address or fetch it: its display username, its canonical (AP) URL, and its friendly URL.

  Lives here rather than in a dance case so any extension's tests can build one, since the tests that federate a group are not the ones that own Categories.
  """
  def fancy_fake_category!(creator, overrides \\ %{}) do
    # `nil` parent explicitly: `fake_category!/2` puts its second argument in the PARENT position, so overrides passed there (eg. `type: :group`) would be silently dropped and you'd get a plain topic
    category = fake_category!(creator, nil, Map.new(overrides))
    display_username = Bonfire.Me.Characters.display_username(category, true)

    [
      category: category,
      username: display_username,
      canonical_url: Bonfire.Me.Characters.character_url(category),
      friendly_url:
        "#{Bonfire.Common.URIs.base_url()}#{Bonfire.Common.URIs.path(category) || "/group/#{display_username}"}"
    ]
  end

  @doc "Same, but created on the OTHER instance of a dance pair."
  def fancy_fake_category_on_test_instance(creator, opts \\ []) do
    Bonfire.Common.TestInstanceRepo.apply(fn -> fancy_fake_category!(creator, opts) end)
  end

  @doc """
  Publishes a post tagged to a topic/category, mirroring what the composer UI does when posting in a topic context.
  """
  def fake_post_in_topic!(user, topic, html \\ "<p>Hello</p>") do
    boundaries =
      List.wrap(Bonfire.Classify.Boundaries.read_default_content_visibility(topic))
      |> Enum.reject(&is_nil/1)

    boundaries = if boundaries == [], do: ["public"], else: boundaries

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: html}},
        context_id: topic.id,
        to_circles: [topic.id],
        to_boundaries: boundaries
      )

    post
  end

  @doc """
  Publishes a post in a group, using the group's stored `default_content_visibility`
  as the post boundary — mirroring what the composer UI does.
  """
  def fake_post_in_group!(user, group, html \\ "<p>Hello</p>") do
    boundaries = List.wrap(Bonfire.Classify.Boundaries.read_default_content_visibility(group))
    require Untangle
    Untangle.info(boundaries, "fake_post_in_group! boundaries from group DCV")

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: html}},
        context_id: group.id,
        to_circles: Bonfire.Classify.Boundaries.post_circles_for_group(group),
        to_boundaries: boundaries
      )

    post
  end
end
