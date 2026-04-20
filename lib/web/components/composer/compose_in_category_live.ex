defmodule Bonfire.UI.Groups.ComposeInCategoryLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop category, :any, required: true
  prop prompt, :any, required: true
end
