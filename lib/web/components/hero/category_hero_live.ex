defmodule Bonfire.Classify.Web.CategoryHeroLive do
  use Bonfire.UI.Common.Web, :stateless_component
  import Bonfire.Classify

  prop category, :map
  prop subcategories, :list, default: nil
  # prop object_boundary, :any, default: nil

  @doc "The CSS class of the swatch the category has set for its colour, nil if it has none (or its settings are not loaded): then its hero has no band."
  def band_class(category),
    do: category |> Bonfire.Classify.Appearance.own_colour() |> Bonfire.Common.Swatches.class()

  @doc "The icon the category has picked (nil if none, or its settings are not loaded), shown when it has no uploaded image."
  def picked_icon(category), do: Bonfire.Classify.Appearance.icon(category)

  @doc "Whether the category has an uploaded image (or banner) for its round picture."
  def has_image?(category),
    do: is_binary(Media.image_url(category) || Media.banner_url(category, fallback: false))

  def category_link(category) do
    id = e(category, :character, :username, nil) || e(category, :id, "#no-parent")

    "/+" <> id
  end
end
