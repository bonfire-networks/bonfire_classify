defmodule Bonfire.Classify.Web.CategoryHeroLive do
  use Bonfire.UI.Common.Web, :stateless_component
  import Bonfire.Classify

  prop category, :map
  prop subcategories, :list, default: nil
  # prop object_boundary, :any, default: nil

  def category_link(category) do
    id = e(category, :character, :username, nil) || e(category, :id, "#no-parent")

    "/+" <> id
  end
end
