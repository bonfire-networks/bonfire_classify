defmodule Bonfire.Classify.Web.CategoryActionsLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop object, :any
  prop object_type, :any, default: nil
  prop activity_id, :string, default: nil
  prop object_boundary, :any, default: nil
end
