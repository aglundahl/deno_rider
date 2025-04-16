defmodule DenoRider.MixProject do
  use Mix.Project

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def project do
    [
      app: :deno_rider,
      deps: deps(),
      description:
        "DenoRider is an embedded JavaScript runtime via Rustler. It is a performant way to run JavaScript in Elixir and it doesn't depend on external executables.",
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ],
      docs: [
        extras: [
          "LICENSE",
          "README.md"
        ],
        main: "readme"
      ],
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      homepage_url: "https://github.com/aglundahl/deno_rider",
      name: "DenoRider",
      package: [
        files: [
          "checksum-Elixir.DenoRider.Native.exs",
          "LICENSE",
          "lib",
          "native",
          "mix.exs",
          "priv/main.js",
          "README.md"
        ],
        licenses: ["MIT"],
        links: %{
          "GitHub" => "https://github.com/aglundahl/deno_rider"
        },
        maintainers: ["Andreas Geffen Lundahl"]
      ],
      source_url: "https://github.com/aglundahl/deno_rider",
      start_permanent: Mix.env() == :prod,
      version: "0.3.0"
    ]
  end

  defp deps do
    [
      {:benchee, "~> 1.3", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:jason, "~> 1.4"},
      {:rustler, "~> 0.35", optional: true},
      {:rustler_precompiled, "~> 0.7"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
