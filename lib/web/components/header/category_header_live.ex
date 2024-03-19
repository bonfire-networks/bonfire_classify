defmodule Bonfire.Classify.Web.CategoryHeaderLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop category, :map, required: true
  # prop subcategories, :list, default: nil
  prop object_boundary, :any, default: nil
end
