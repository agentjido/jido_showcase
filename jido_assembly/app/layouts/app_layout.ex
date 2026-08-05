defmodule Jido.Assembly.Layouts.App do
  use Hologram.Component

  alias Hologram.UI.Runtime

  def template do
    ~HOLO"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Jido Assembly</title>
        <link rel="stylesheet" href="/assets/css/app.css?v=slack-ui" />
        <script defer src="/assets/js/app.js?v=chat-scroll"></script>
        <Runtime />
      </head>
      <body>
        <slot />
      </body>
    </html>
    """
  end
end
