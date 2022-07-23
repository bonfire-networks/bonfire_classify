defmodule Bonfire.Classify.Web.NewCategoryLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop category, :any, default: nil

  slot header

end
