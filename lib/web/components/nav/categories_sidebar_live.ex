defmodule Bonfire.Classify.Web.CategoriesSidebarLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop page, :string


  declare_nav_component("Links to main topics pages", exclude_from_nav: true)

end
