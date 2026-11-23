defmodule Bonfire.Classify.Appearance do
  @moduledoc """
  The colour and the icon of a group, topic or label (a `Bonfire.Classify.Category`), kept in its own settings (`[:ui, :colour]` and `[:ui, :icon]`, scoped to the category).

  The colour is a swatch name (`Bonfire.Common.Swatches`). `colour/1` is the category's own, else its parent's (a topic or a group, going up), else a swatch hashed from its id, so every category has one and the same one every time. The icon is the category's own only, or nil.

  These only read what is on the struct, never loading it, so a category whose `:settings` (or `:parent_category`) are not preloaded is as if it had none set: callers that want them preload first (`preload/1`).
  """
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo
  alias Bonfire.Common.Settings
  alias Bonfire.Common.Swatches

  # a parent chain that loops (it should not) ends here
  @max_depth 10

  @doc "The preloads a lookup reads: the settings and the parent's settings (it works on a pointer with its mixins too, as an event's tags are)."
  def preloads, do: [:settings, tree: [parent: [:settings]]]

  @doc "Preloads what a lookup reads (`preloads/0`): one batched query for each level, for a list too."
  def preload(categories), do: repo().maybe_preload(categories, preloads())

  @doc """
  The swatch name the category shows: its own, else its parent's (and the parent's parent's, as far as they are loaded), else the one hashed from its id. nil only for no category.
  """
  def colour(category) do
    case category && id(category) do
      nil -> nil
      id -> inherited_or_own_colour(category, @max_depth) || Swatches.from_seed(id)
    end
  end

  @doc "Whether the category's settings are loaded: if not, what `colour/1` and `icon/1` give is only the fallback, so a caller that would rather show nothing than a fallback checks this."
  def settings_loaded?(%{settings: %Ecto.Association.NotLoaded{}}), do: false
  def settings_loaded?(%{settings: _}), do: true
  def settings_loaded?(_), do: false

  @doc "The swatch name the category has set itself, if any (a name outside the set counts as none)."
  def own_colour(category), do: setting(category, :colour) |> Swatches.normalize()

  @doc "The icon name the category has set, if any."
  def icon(category) do
    case setting(category, :icon) do
      icon when is_binary(icon) and icon != "" -> icon
      icon when is_atom(icon) and not is_nil(icon) -> Atom.to_string(icon)
      _ -> nil
    end
  end

  @doc "Whether the user may change the category's colour and icon: whoever may edit the category's other settings (`Bonfire.Classify.ensure_update_allowed/2`: its creator, those who can edit or moderate it, and the instance's admins)."
  def can_edit?(nil, _category), do: false
  def can_edit?(_user, nil), do: false

  def can_edit?(user, category),
    do: !!Bonfire.Classify.ensure_update_allowed(user, category)

  @doc "Sets the category's colour to a swatch of the set (`opts` as for `Bonfire.Common.Settings.put/3`, with the `current_user`)."
  def set_colour(category, swatch, opts) do
    with swatch when is_binary(swatch) <-
           Swatches.normalize(swatch) || {:error, :unknown_swatch},
         :ok <- allowed(category, opts) do
      put(category, :colour, swatch, opts)
    end
  end

  @doc "Sets the category's icon to a name like `ph:music-notes-fill`."
  def set_icon(category, icon, opts) do
    with icon when is_binary(icon) <- well_formed_icon(icon) || {:error, :invalid_icon},
         :ok <- allowed(category, opts) do
      put(category, :icon, icon, opts)
    end
  end

  @doc "Removes the category's own colour, so its parent's or the hashed one shows again."
  def reset_colour(category, opts), do: reset(category, :colour, opts)

  @doc "Removes the category's own icon."
  def reset_icon(category, opts), do: reset(category, :icon, opts)

  # `family:name`, as the icon sets name theirs (eg. `ph:music-notes-fill`)
  defp well_formed_icon(icon) when is_binary(icon),
    do: if(Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*:[a-z0-9]+(-[a-z0-9]+)*$/, icon), do: icon)

  defp well_formed_icon(_), do: nil

  defp allowed(category, opts) do
    if opts[:skip_boundary_check] == true or can_edit?(current_user(opts), category),
      do: :ok,
      else: {:error, :not_permitted}
  end

  # `allowed/2` has already checked: a scoped write would check `:configure` on the category again, which those who may edit it need not hold (an admin, a moderator)
  defp put(category, key, value, opts),
    do: Settings.put([:ui, key], value, scope_opts(category, opts))

  defp reset(category, key, opts) do
    with :ok <- allowed(category, opts) do
      Settings.delete([:ui, key], scope_opts(category, opts))
    end
  end

  defp scope_opts(category, opts),
    do:
      opts
      |> Keyword.put(:scope, fresh_settings(category))
      |> Keyword.put(:skip_boundary_check, true)

  # a write merges into the settings the struct holds, so a struct that holds old ones (or none, loaded before the other thing was set) would drop it: they are read again (one query)
  defp fresh_settings(category), do: repo().preload(category, :settings, force: true)

  defp inherited_or_own_colour(_category, 0), do: nil

  defp inherited_or_own_colour(category, depth) do
    own_colour(category) ||
      case parent_of(category) do
        nil -> nil
        parent -> inherited_or_own_colour(parent, depth - 1)
      end
  end

  # a category's parent where it is loaded: as `:parent_category`, or through its `:tree` (a tag of an event is a bare pointer with its mixins, which has the tree but not the assoc through it)
  # (both may be loaded, one without its settings: the one that has them is the parent to read)
  defp parent_of(category) do
    parents = [
      loaded(category, :parent_category),
      case loaded(category, :tree) do
        nil -> nil
        tree -> loaded(tree, :parent)
      end
    ]

    Enum.find(parents, &(&1 && settings_loaded?(&1))) || Enum.find(parents, & &1)
  end

  # what the struct holds, never loading anything: no settings loaded reads as no setting
  defp setting(category, key) do
    if loaded(category, :settings),
      do:
        Settings.get([:ui, key], nil, scope: category, one_scope_only: true)
        |> blank_to_nil()
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp loaded(%{} = struct, assoc) do
    case Map.get(struct, assoc) do
      %Ecto.Association.NotLoaded{} -> nil
      loaded -> loaded
    end
  end

  defp loaded(_, _), do: nil
end
