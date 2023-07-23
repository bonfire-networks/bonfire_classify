defmodule Bonfire.Classify.Web.WidgetAboutLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop date, :string, default: nil
  prop parent, :string, default: nil
  prop parent_link, :string, default: nil
  prop boundary_preset, :any, default: nil
  prop category, :map, default: nil
  prop member_count, :integer, default: 0
end
