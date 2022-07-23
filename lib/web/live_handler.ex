defmodule Bonfire.Classify.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler

  def handle_event("new", %{"name" => name} = attrs, socket) do
    current_user = current_user(socket)
    if(is_nil(name) or !current_user) do
      error(attrs)
      {:noreply,
       socket
       |> assign_flash(:error, "Please enter a name...")}
    else
      params = input_to_atoms(attrs)
      debug(attrs, "category to create")

      {:ok, category} =
        Bonfire.Classify.Categories.create(
          current_user,
          %{category: params, parent_category: e(params, :context_id, nil)}
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
         socket
         |> redirect_to("/categories/")}
      end
    end
  end
end
