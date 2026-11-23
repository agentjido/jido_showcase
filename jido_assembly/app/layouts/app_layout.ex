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
        <meta name="theme-color" content="#222d49" />
        <title>Jido Assembly</title>
        <link rel="stylesheet" href="/assets/css/app.css?v=work-threads" />
        <script defer src="/assets/js/app.js?v=work-links"></script>
        <Runtime />
      </head>
      <body>
        <slot />
      </body>
    </html>
    """
  end
end
