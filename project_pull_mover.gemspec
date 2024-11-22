Gem::Specification.new do |s|
  s.name          = "project_pull_mover"
  s.version       = "0.0.1"
  s.summary       = "Script to change the status of a pull request in a GitHub project."
  s.description   = "Script to change the status of pull requests in a GitHub project, including marking them as draft, based on failing required checks, whether the PR is enqueued, etc."
  s.authors       = ["Sarah Vessels"]
  s.email         = "cheshire137@gmail.com"
  s.files         = Dir['lib/**/*'] + %w[LICENSE README.md]
  s.bindir        = "bin"
  s.require_paths = ["lib"]
  s.executables   = ["project_pull_mover"]
  s.homepage      = "https://github.com/cheshire137/project-pull-mover"
  s.license       = "MIT"
end
