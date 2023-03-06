defmodule Bonfire.Classify.Web.CategoryHeaderAsideLive do
  use Bonfire.UI.Common.Web, :stateless_component
  import Bonfire.Classify

  prop category, :map
  prop showing_within, :atom
end
