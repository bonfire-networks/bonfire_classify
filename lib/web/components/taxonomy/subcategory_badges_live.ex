defmodule Bonfire.Classify.Web.SubcategoryBadgesLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop category, :map, required: false
  prop subcategories, :list, default: nil
end
