defmodule Bonfire.Classify.Web.Preview.CategoryLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop object, :any
  prop activity, :any, default: nil
  prop object_boundary, :any, default: nil
  prop permalink, :string, default: nil
  prop showing_within, :atom, default: nil

  def preloads(),
    do: [
      :character,
      :profile,
      # the card of a group or topic marked sensitive blurs its images and hides its description
      :sensitive,
      parent_category: [:profile, :character]
    ]

  @doc "The DOM id of one part (`icon`, `banner`, `summary`) that the card of a group or topic marked sensitive covers, one per card and variant."
  def sensitive_part_id(part, object, showing_within),
    do:
      deterministic_dom_id(
        "sensitive-content-#{part}",
        id(object),
        "category_card",
        showing_within
      )

  @doc "Shows what the card of a group or topic marked sensitive covers: takes the blur off its icon and banner, and shows its description. In the browser only, so nothing is remembered."
  def show_sensitive(object, showing_within) do
    JS.hide(to: "#" <> sensitive_part_id("icon", object, showing_within), transition: "fade-out")
    |> JS.hide(
      to: "#" <> sensitive_part_id("banner", object, showing_within),
      transition: "fade-out"
    )
    |> JS.remove_class("hidden", to: "#" <> sensitive_part_id("summary", object, showing_within))
  end

  def name(object, fallback \\ l("Unnamed category")) do
    e(object, :name, nil) ||
      e(object, :profile, :name, nil) ||
      e(object, :post_content, :name, nil) ||
      e(object, :title, nil) ||
      e(object, :character, :username, nil) ||
      fallback
  end

  @doc "Iconify name for a category, keyed off its type (:topic / :group)."
  def icon(object, fallback \\ "ph:users-three-duotone") do
    case e(object, :type, nil) do
      :topic -> "ph:hash-duotone"
      :group -> "ph:users-three-duotone"
      _ -> fallback
    end
  end

  # TODO: preload?
  # defp crumbs(%{name: name, parent: grandparent} = _parent) do
  #   crumbs(grandparent) <> crumb_link(name)
  # end

  # defp crumbs(%{name: name}) do
  #   crumb_link(name)
  # end

  # defp crumbs(_) do
  #   ""
  # end

  def crumb_link(name) do
    "<a data-phx-link='redirect' data-phx-link-state='push' href='/+#{name}' target='_top'>#{name}</a> > "
  end
end
