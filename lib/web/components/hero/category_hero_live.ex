defmodule Bonfire.Classify.Web.CategoryHeroLive do
  use Bonfire.UI.Common.Web, :stateless_component
  # import Bonfire.UI.Me.Integration

  prop category, :map
  prop subcategories, :list, default: nil
  prop object_boundary, :any, default: nil

  def display_url("https://"<>url), do: url
  def display_url("http://"<>url), do: url
  def display_url(url), do: url

end
