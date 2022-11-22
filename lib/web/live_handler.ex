defmodule Bonfire.Classify.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler

  def handle_event("autocomplete", %{"input" => input}, socket) do
    suggestions =
      Bonfire.Tag.Autocomplete.tag_lookup_public(
        input,
        Bonfire.Classify.Category
      )
      |> debug()

    {:noreply,
     assign(socket,
       autocomplete: (e(socket.assigns, :autocomplete, []) ++ suggestions) |> Enum.uniq()
     )}
  end

  def handle_event("input_category", attrs, socket) do
    Bonfire.UI.Common.SmartInputLive.set(socket.assigns[:__context__],
      create_object_type: :category,
      # to_boundaries: [Bonfire.Boundaries.preset_boundary_tuple_from_acl(e(socket.assigns, :object_boundary, nil))],
      activity_inception: "reply_to",
      # TODO: use assigns_merge and send_update to the ActivityLive component within smart_input instead, so that `update/2` isn't triggered again
      # activity: activity,
      object: e(attrs, "parent_id", nil) || e(socket.assigns, :category, nil)
    )

    {:noreply, socket}
  end

  def handle_event("new", %{"name" => name} = attrs, socket) do
    current_user = current_user_required!(socket)

    if(is_nil(name) or !current_user) do
      error(attrs)

      {:noreply, assign_flash(socket, :error, "Please enter a name...")}
    else
      debug(attrs, "category inputs")

      with uploaded_media <-
             live_upload_files(
               current_user,
               attrs["upload_metadata"],
               socket
             ),
           params <-
             attrs
             # |> debug()
             |> Map.merge(attrs["category"] || %{})
             |> Map.drop(["category", "_csrf_token"])
             |> input_to_atoms()
             # |> Map.get(:event)
             |> maybe_put(:image_id, ulid(List.first(uploaded_media)))
             |> debug("create category attrs"),
           {:ok, category} <-
             Bonfire.Classify.Categories.create(
               current_user,
               %{category: params, parent_category: e(params, :context_id, nil)}
             ) do
        # TODO: handle errors
        debug(category, "category created")

        id = e(category, :character, :username, nil) || category.id

        if(id) do
          {:noreply,
           socket
           |> assign_flash(:info, l("Category created!"))
           # change redirect
           |> redirect_to("/+" <> id)}
        else
          {:noreply,
           redirect_to(
             socket,
             "/categories/"
           )}
        end
      end
    end
  end

  def handle_event("category_edit", attrs, socket) do
    current_user = current_user_required!(socket)
    category = e(socket.assigns, :category, nil)

    if(!current_user || !category) do
      # error(attrs)
      {:noreply, assign_flash(socket, :error, l("Please log in..."))}
    else
      params = input_to_atoms(attrs)
      debug(attrs, "category to update")

      with {:ok, category} <-
             Bonfire.Classify.Categories.update(
               current_user,
               category,
               %{category: params}
             ),
           id when is_binary(id) <-
             e(category, :character, :username, nil) || ulid(category) do
        {:noreply,
         socket
         |> assign_flash(:info, l("Category updated!"))
         # change redirect
         |> redirect_to("/+" <> id)}
      end
    end
  end

  def handle_event("category_archive", _, socket) do
    category = e(socket.assigns, :category, nil)

    with {:ok, _circle} <-
           Bonfire.Classify.Categories.soft_delete(
             category,
             current_user_required!(socket)
           )
           |> debug() do
      {:noreply,
       socket
       |> assign_flash(:info, l("Deleted"))
       |> redirect_to("/topics")}
    end
  end
end
