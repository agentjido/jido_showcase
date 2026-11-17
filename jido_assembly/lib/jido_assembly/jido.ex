defmodule Jido.Assembly.Jido do
  @moduledoc """
  Host-owned Jido V3 instance for Assembly chat Rooms and AI Agents.
  """

  use Jido,
    otp_app: :jido_assembly,
    namespace: "jido-assembly/v3"
end
