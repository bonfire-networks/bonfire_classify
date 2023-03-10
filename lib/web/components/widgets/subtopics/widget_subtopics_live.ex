defmodule Bonfire.Classify.Web.WidgetSubtopicsLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop widget_title, :string, default: nil
  prop subcategories, :any, default: nil
  prop category, :list, default: []
end
