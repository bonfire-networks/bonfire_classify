defmodule Bonfire.Classify.Web.CategoriesNavLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop topics, :list, default: []

  def topics(context) do
    current_user = current_user(context)
    # params = e(context, :current_params, %{})

    # TODO: configurable
    limit = 5
    type = Bonfire.Classify.Category

    if current_user do
      favs =
        Bonfire.Social.Likes.list_my(current_user: current_user, limit: limit, object_types: type)
        |> debug()
        |> e(:edges, [])
        |> Enum.map(&e(&1, :edge, :object, nil))

      # |> debug("TESTTTT")
      followed =
        Bonfire.Social.Graph.Follows.list_my_followed(current_user,
          limit: limit,
          type: type
        )
        |> e(:edges, [])
        |> Enum.map(&e(&1, :edge, :object, nil))

      Enum.uniq_by(favs ++ followed, & &1.id)
    else
      []
    end
  end

  def category_link(category, context) do
    if e(context, :category_link_prefix, nil) do
      e(context, :category_link_prefix, "/+") <> e(category, :id, "")
    else
      id = e(category, :character, :username, nil) || e(category, :id, "")

      "/+" <> id
    end
  end
end
