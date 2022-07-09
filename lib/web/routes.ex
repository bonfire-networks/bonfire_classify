defmodule Bonfire.Classify.Web.Routes do
  defmacro __using__(_) do

    quote do

      # pages anyone can view
      scope "/", Bonfire.Classify.Web do
        pipe_through :browser

        live "/categories", InstanceLive.InstanceCategoriesPageLive
        live "/category/:id", Page.Category
        live "/+:id", Page.Category

      end

      # pages you need an account to view
      scope "/", Bonfire.Classify.Web do
        pipe_through :browser
        pipe_through :account_required

      end

      # pages you need to view as a user
      scope "/", Bonfire.Classify.Web do
        pipe_through :browser
        pipe_through :user_required


      end

    end
  end
end
