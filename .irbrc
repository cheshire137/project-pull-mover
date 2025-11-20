require_relative "lib/project_pull_mover"

logger = nil
def load_logger
  logger ||= ProjectPullMover::Logger.new(out_stream: $stdout, err_stream: $stderr)
end

options = nil
def load_options(argv: ARGV, logger: nil)
  options ||= ProjectPullMover::Options.parse(argv: argv, proj_items_limit: 500, pull_fields_per_query: 7,
    logger: logger || load_logger)
end

gh_cli = nil
def load_gh_cli(options: nil, logger: nil)
  lgr = logger || load_logger
  gh_cli ||= ProjectPullMover::GhCli.new(options: options || load_options(logger: lgr), logger: lgr)
end

data_loader = nil
def load_data_loader(gh_cli: nil, options: nil, logger: nil)
  lgr = logger || load_logger
  opts = options || load_options(logger: lgr)
  cli = gh_cli || load_gh_cli(options: opts, logger: lgr)
  data_loader ||= ProjectPullMover::DataLoader.call(gh_cli: cli, options: opts, logger: lgr)
end

def run(data_loader: nil, options: nil, logger: nil)
  lgr = logger || load_logger
  opts = options || load_options(logger: lgr)
  data = data_loader || load_data_loader(logger: lgr, options: opts)
  ProjectPullMover::PullRequestMover.run(data: data, options: opts, logger: lgr)
end
