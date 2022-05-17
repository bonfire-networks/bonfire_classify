defmodule Bonfire.Classify.Web.InstanceLive.InstanceCategoriesPageLive do
  use Bonfire.UI.Common.Web, :live_view
  alias Bonfire.UI.Me.LivePlugs

  def mount(params, session, socket) do
    live_plug params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      LivePlugs.LoadCurrentUserCircles,
      Bonfire.UI.Common.LivePlugs.StaticChanged,
      Bonfire.UI.Common.LivePlugs.Csrf,
      Bonfire.UI.Common.LivePlugs.Locale,
      &mounted/3
    ]
  end

  defp mounted(params, _session, socket) do

    {:ok,
     socket |> assign(page: 1)}
  end

  def render(assigns) do
    ~L"""
    <%= live_component(
      @socket,
      Bonfire.Classify.Web.InstanceLive.InstanceCategoriesLive,
      # selected_tab: @selected_tab,
      id: :categories,
      categories: [],
      page: 1,
      has_next_page: false,
      after: [],
      before: [],
      pagination_target: "#instance-categories"
    ) %>
    """
  end
end
