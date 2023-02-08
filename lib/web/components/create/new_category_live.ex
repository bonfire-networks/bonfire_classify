defmodule Bonfire.Classify.Web.NewCategoryLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop category, :any, default: nil
  prop object, :any, default: nil
  prop context_id, :any, default: nil

  prop smart_input_opts, :map, default: %{}
  prop textarea_class, :css_class, required: false
  # unused but workaround surface "invalid value for property" issue
  prop textarea_container_class, :css_class
  prop to_boundaries, :any, default: nil
  prop open_boundaries, :boolean, default: false
  prop create_object_type, :any, default: :category
  prop to_circles, :list, default: []
  prop showing_within, :string, default: nil
  prop uploads, :any, default: nil
  prop uploaded_files, :list, default: nil

  slot header
end
