defmodule Bonfire.Classify.Web.SensitiveSwitchLive do
  @moduledoc """
  The "mark as sensitive" checkbox of a group's or a topic's settings form. It sends `category[sensitive]`, which `Bonfire.Classify.Categories.update/4` saves. A mirror's mark is its origin's to set, so a mirror gets no switch.

  It is ticked from the saved mark. A form with a `change` event that re-renders it would set the box back to that on every click, so put it only in a form without one.
  """
  use Bonfire.UI.Common.Web, :stateless_component

  @doc "The group or topic"
  prop category, :any, required: true

  @doc "The checkbox's DOM id, unique on the page"
  prop id, :string, required: true

  prop label, :string, required: true

  @doc "Says what the mark does, under the checkbox"
  prop help, :string, default: nil
end
