ExUnit.start(
  exclude: [:assembly_target, :assembly_live],
  formatters: [ExUnit.CLIFormatter, Jido.Assembly.LiveAcceptanceFormatter]
)

test_db = Application.fetch_env!(:jido_assembly, :sqlite_path)

ExUnit.after_suite(fn _results ->
  Application.stop(:jido_assembly)

  for path <- [test_db, test_db <> "-wal", test_db <> "-shm"], do: File.rm(path)
end)
