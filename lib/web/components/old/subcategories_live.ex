defmodule Bonfire.UI.Topics.CategoryLive.SubcategoriesLive do
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
    # debug(assigns)

    {:ok, categories} =
      Bonfire.Classify.GraphQL.CategoryResolver.category_children(
        %{id: assigns.category_id},
        %{limit: 15},
        %{context: %{current_user: current_user(assigns) || current_user(socket.assigns)}}
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

  # def do_handle_event("load-more", _, socket),
  #   do: paginate_next(&fetch/2, socket)

  def render(assigns) do
    ~H"""
    <div id="subcategories">
      <div class="community__discussion__actions">
        <a phx-target="#new_category" phx-click="toggle_category">
          <button>Define a sub-category</button>
        </a>
      </div>

      <div id="subcategories" phx-update="append" data-page={@page} class="selected__area">
        <%= for category <- @categories do %>
          <div id={"category-#{category.id}-wrapper"} class="preview__wrapper">
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
