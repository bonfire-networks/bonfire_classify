defmodule Bonfire.Classify.Web.WidgetSubtopicsLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop widget_title, :string
  prop subcategories, :list
  prop category, :list
end
