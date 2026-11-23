defmodule Bonfire.Classify.Web.AppearanceLive do
  @moduledoc """
  The colour and icon pickers of a group, topic or label, for settings pages (`Bonfire.UI.Common.SwatchPickerLive` and `Bonfire.UI.Common.IconPickerLive`, saved by `Bonfire.Classify.Appearance` through `Bonfire.Classify.LiveHandler`). Shown only to someone who may configure the category, as saving is refused for anyone else.

  The colour picker marks the category's own colour (none, when it takes its parent's or the hashed one: Reset goes back to that). `icons` is the list of icons offered, `Bonfire.UI.Common.IconPickerLive.curated_icons/0` by default; `nil` offers every compiled icon, with a search.
  """
  use Bonfire.UI.Common.Web, :stateful_component

  alias Bonfire.Classify.Appearance

  prop category, :any, required: true
  @doc "The icons offered (names), the curated set by default, or nil for all"
  prop icons, :any, default: :curated

  def update(assigns, socket) do
    # what a lookup reads, loaded here once rather than at each render
    category = assigns |> Map.fetch!(:category) |> Appearance.preload()

    {:ok, socket |> assign(assigns) |> assign(category: category)}
  end

  @doc "The icons to offer."
  def icons(:curated), do: Bonfire.UI.Common.IconPickerLive.curated_icons()
  def icons(icons), do: icons
end
