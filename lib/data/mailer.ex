defmodule Data.Mailer do
  @moduledoc """
  Outbound email delivery for the application, backed by Swoosh. The
  adapter is environment-specific: local storage in dev
  (see `/dev/mailbox`), the test adapter in test, and a real provider
  configured in `config/runtime.exs` for production.
  """

  use Swoosh.Mailer, otp_app: :data
end
