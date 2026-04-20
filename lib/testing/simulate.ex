# check that this extension is configured
defmodule Bonfire.Classify.Simulate do
  import Bonfire.Common.Simulation

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

  @doc """
  Publishes a post in a group, using the group's stored `default_content_visibility`
  as the post boundary — mirroring what the composer UI does.
  """
  def fake_post_in_group!(user, group, html \\ "<p>Hello</p>") do
    boundary = Bonfire.Classify.Boundaries.read_default_content_visibility(group) |> to_string()
    require Untangle
    Untangle.info(boundary, "fake_post_in_group! boundary from group DCV")

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: html}},
        context_id: group.id,
        to_circles: Bonfire.Classify.Boundaries.post_circles_for_group(group),
        to_boundaries: [boundary]
      )

    post
  end
end
