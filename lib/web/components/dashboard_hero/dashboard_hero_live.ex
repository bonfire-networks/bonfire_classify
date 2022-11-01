defmodule Bonfire.Classify.Web.DashboardHeroLive do
  use Bonfire.UI.Common.Web, :stateless_component
  import Bonfire.Classify

  # prop object_boundary, :any, default: nil
  prop page, :string, default: nil
  prop selected_tab, :string, default: nil

  def display_url("https://" <> url), do: url
  def display_url("http://" <> url), do: url
  def display_url(url), do: url
end
