defmodule Bonfire.Classify.Web.InstanceLive.InstanceCategoriesLive do
  use Bonfire.UI.Common.Web, :live_component

  # alias CommonsPub.Profiles.Web.ProfilesHelper

  alias Bonfire.Classify.Web.Component.CategoryPreviewLive

  def update(assigns, socket) do
    {
      :ok,
      socket
      |> assign(assigns)
      |> fetch_assigns(assigns)
    }
  end

  def fetch_assigns(socket, assigns) do
    {:ok, categories} =
      Bonfire.Classify.GraphQL.CategoryResolver.categories_toplevel(
        %{limit: 10},
        %{context: %{current_user: current_user(assigns) || current_user(socket)}}
      )

    # debug(categories: categories)

    # categories_list =
    #   Enum.map(
    #     categories.edges,
    #     &prepare_common(&1)
    #   )

    assign(socket,
      categories: categories.edges,
      has_next_page: categories.page_info.has_next_page,
      after: categories.page_info.end_cursor,
      before: categories.page_info.start_cursor
    )
  end

  # def handle_event("load-more", _, socket),
  #   do: paginate_next(&fetch/2, socket)

  def render(assigns) do
    ~H"""
    <div id="instance-categories">
      <div
        id="selected-instance-categories"
        phx-update="append"
        data-page={@page}
        class="selected__area"
      >
        <%= for category <- @categories do %>
          <div class="preview__wrapper" id={"category-#{category.id}-wrapper"}>
            <.live_component
              module={CategoryPreviewLive}
              id={"category-#{id(category)}"}
              object={@category}
            />
          </div>
        <% end %>
      </div>
      <%= if @has_next_page do %>
        <div class="pagination">
          <button class="button--outline" phx-click="load-more" phx-target={@pagination_target}>
            load more
          </button>
        </div>
      <% end %>
    </div>
    """
  end
end
