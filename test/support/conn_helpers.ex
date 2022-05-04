defmodule Bonfire.Classify.Test.ConnHelpers do

  import ExUnit.Assertions
  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  # alias CommonsPub.Accounts
  alias Bonfire.Data.Identity.Account

  @endpoint Bonfire.Common.Config.get!(:endpoint_module)

  ### conn

  def session_conn(conn \\ build_conn()), do: Plug.Test.init_test_session(conn, %{})



end
