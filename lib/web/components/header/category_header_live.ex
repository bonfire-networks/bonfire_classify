defmodule Bonfire.Classify.Web.CategoryHeaderLive do
  use Bonfire.UI.Common.Web, :stateless_component
  # import Bonfire.UI.Me.Integration

  prop category, :map, required: true
  # prop subcategories, :list, default: nil
  prop object_boundary, :any, default: nil

  def display_url("https://" <> url), do: url
  def display_url("http://" <> url), do: url
  def display_url(url), do: url
end
