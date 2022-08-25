defmodule Bonfire.Classify.Web.BreadcrumbsLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop category, :map
  prop top_level_category, :string, default: nil
  prop object_boundary, :any, default: nil

  def category_link(category) do
    id = e(category, :character, :username, nil) || e(category, :id, "#no-parent")

    "/+" <> id
  end

end
