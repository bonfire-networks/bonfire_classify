defmodule Bonfire.Classify.Web.NewCategoryLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop category, :any, default: nil
  prop object, :any, default: nil
  prop textarea_class, :css_class, default: nil
  # unused but workaround surface "invalid value for property" issue
  prop textarea_container_class, :css_class
  prop to_boundaries, :list, default: nil
  prop open_boundaries, :boolean, default: false

  slot header
end
