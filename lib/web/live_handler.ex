defmodule Bonfire.Classify.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler

  def handle_event("input_category", attrs, socket) do
    send_update(Bonfire.UI.Common.SmartInputLive, # assigns_merge(socket.assigns,
        id: :smart_input,
        create_activity_type: :category,
        # to_boundaries: [Bonfire.Boundaries.preset_boundary_tuple_from_acl(e(socket.assigns, :object_boundary, nil))],
        activity_inception: "reply_to",
        # TODO: use assigns_merge and send_update to the ActivityLive component within smart_input instead, so that `update/2` isn't triggered again
        # activity: activity,
        object: e(socket.assigns, :category, nil)
      )
    {:noreply,
       socket
     }
  end

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

      id = e(category, :character, :username, nil) || category.id

      if(id) do
        {:noreply,
         socket
         |> assign_flash(:info, l "Category created!")
         # change redirect
         |> redirect_to("/+" <> id)}
      else
        {:noreply,
         socket
         |> redirect_to("/categories/")}
      end
    end
  end

  def handle_event("category_edit", attrs, socket) do
    current_user = current_user(socket)
    category = e(socket.assigns, :category, nil)

    if(!current_user || !category) do
      # error(attrs)
      {:noreply,
       socket
       |> assign_flash(:error, l "Please log in...")}
    else
      params = input_to_atoms(attrs)
      debug(attrs, "category to update")

      {:ok, category} =
        Bonfire.Classify.Categories.update(
          current_user,
          category,
          %{category: params}
        )

      # TODO: handle errors
      debug(category, "category updated")

      id = e(category, :character, :username, nil) || category.id

      if(id) do
        {:noreply,
         socket
         |> assign_flash(:info, l "Category updated!")
         # change redirect
         |> redirect_to("/+" <> id)}
      else
        {:noreply,
         socket
         |> redirect_to("/categories/")}
      end
    end
  end

  def handle_event("category_archive", _, socket) do
    category = e(socket.assigns, :category, nil)

    with {:ok, _circle} <-
      Bonfire.Classify.Categories.soft_delete(category) |> debug do

      {:noreply,
        socket
        |> assign_flash(:info, l "Deleted")
        |> redirect_to("/topics")
      }
    end
  end
end
