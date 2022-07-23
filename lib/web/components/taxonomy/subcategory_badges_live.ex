defmodule Bonfire.Classify.Web.SubcategoryBadgesLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop category, :map, required: true
  prop subcategories, :list, default: []

end
