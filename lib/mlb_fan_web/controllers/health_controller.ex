defmodule MlbFanWeb.HealthController do
  @moduledoc """
  Liveness/readiness endpoint used by the container `HEALTHCHECK` and load
  balancers. Returns 200 with a tiny JSON body and never touches secrets.
  """
  use MlbFanWeb, :controller

  def index(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, ~s({"status":"ok"}))
  end
end
