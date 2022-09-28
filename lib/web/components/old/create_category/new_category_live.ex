defmodule Bonfire.Classify.Web.My.NewCategoryLive do
  use Bonfire.UI.Common.Web, :live_component

  def update(assigns, socket) do
    {
      :ok,
      assign(
        socket,
        assigns
      )
    }
  end

  def handle_event("toggle_category", _data, socket) do
    {:noreply, assign(socket, :toggle_category, !socket.assigns.toggle_category)}
  end

  def handle_event("Bonfire.Classify:new", %{"name" => name} = data, socket) do
    current_user = current_user_required(socket)

    if(is_nil(name) or !current_user) do
      error(data)

      {:noreply, assign_flash(socket, :error, "Please enter a name...")}
    else
      category = input_to_atoms(data)
      debug(data, "category to create")

      {:ok, category} =
        Bonfire.Classify.Categories.create(
          current_user,
          %{category: category, parent_category: e(data, :context_id, nil)}
        )

      # TODO: handle errors
      debug(category, "category created")

      id = category.character.username || category.id

      if(id) do
        {:noreply,
         socket
         |> assign_flash(:info, "Category created!")
         # change redirect
         |> redirect_to("/+" <> id)}
      else
        {:noreply,
         redirect_to(
           socket,
           "/instance/categories/"
         )}
      end
    end
  end
end
