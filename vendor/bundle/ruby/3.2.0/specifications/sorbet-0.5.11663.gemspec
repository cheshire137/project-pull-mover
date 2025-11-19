# -*- encoding: utf-8 -*-
# stub: sorbet 0.5.11663 ruby lib

Gem::Specification.new do |s|
  s.name = "sorbet".freeze
  s.version = "0.5.11663"

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.metadata = { "source_code_uri" => "https://github.com/sorbet/sorbet" } if s.respond_to? :metadata=
  s.require_paths = ["lib".freeze]
  s.authors = ["Stripe".freeze]
  s.date = "2024-11-23"
  s.description = "The main entrypoint for using Sorbet".freeze
  s.email = "sorbet@stripe.com".freeze
  s.executables = ["srb".freeze, "srb-rbi".freeze]
  s.files = ["bin/srb".freeze, "bin/srb-rbi".freeze]
  s.homepage = "https://sorbet.org".freeze
  s.licenses = ["Apache-2.0".freeze]
  s.required_ruby_version = Gem::Requirement.new(">= 2.7.0".freeze)
  s.rubygems_version = "3.4.20".freeze
  s.summary = "A Typechecker for Ruby".freeze

  s.installed_by_version = "3.4.20" if s.respond_to? :installed_by_version

  s.specification_version = 4

  s.add_runtime_dependency(%q<sorbet-static>.freeze, ["= 0.5.11663"])
  s.add_development_dependency(%q<minitest>.freeze, ["~> 5.11"])
  s.add_development_dependency(%q<mocha>.freeze, ["~> 1.7"])
  s.add_development_dependency(%q<rake>.freeze, [">= 0"])
end
