#!/usr/bin/env ruby
# typed: false
# encoding: utf-8

require "optparse"
require "json"
require_relative "project_pull_mover/logger"
require_relative "project_pull_mover/utils"

logger = ProjectPullMover::Logger.new(out_stream: $stdout, err_stream: $stderr)

options = {}
option_parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{__FILE__} [options]"
  opts.on("-h PATH", "--gh-path", String, "Path to gh executable")
  opts.on("-u AUTHOR", "--author", String, "Specify a username so that only PRs authored by that user are changed")
end
option_parser.parse!(into: options)

author = options[:"author"]
if author.nil? || author.strip.size < 1
  logger.error("Author is required")
  puts option_parser
  exit 1
end

gh_path = options[:"gh-path"] || ProjectPullMover::Utils.which("gh") || "gh"
quiet_mode = options[:quiet]
pulls_limit = 500
pull_fields_per_query = 7

logger.loading("Looking up pull requests owned by @#{author}...")
pulls_by_author_cmd = "#{gh_path} search prs --author \"#{author}\" --json \"number,repository\" --limit " \
  "#{pulls_limit} --state open"
json = `#{pulls_by_author_cmd}`
if json.nil? || json == ""
  logger.error("Error: no JSON results for pull requests by author; command: #{pulls_by_author_cmd}")
  exit 1
end

pull_numbers_by_repo_nwo = JSON.parse(json).each_with_object({}) do |data, hash|
  repo_nwo = data["repository"]["nameWithOwner"]
  hash[repo_nwo] ||= []
  hash[repo_nwo] << data["number"]
end

unless quiet_mode
  if pull_numbers_by_repo_nwo.empty?
    logger.info("No pull requests found for @#{author}")
    logger.success("Done!")
    exit 0
  end

  pull_numbers_by_repo_nwo.each do |repo_nwo, pull_numbers|
    units = pull_numbers.size == 1 ? "pull request" : "pull requests"
    logger.info("Found #{pull_numbers.size} #{units} in #{repo_nwo}")
  end
end

pull_graphql_fields = []
pull_numbers_by_repo_nwo.each do |repo_nwo, pull_numbers|
  repo_owner, repo_name = repo_nwo.split("/")
  graphql_field_alias_prefix = "pull#{ProjectPullMover::Utils.replace_hyphens(repo_owner)}" \
    "#{ProjectPullMover::Utils.replace_hyphens(repo_name)}"
  pull_numbers.each do |number|
    graphql_field_alias = "#{graphql_field_alias_prefix}#{number}"
    graphql_field = <<~GRAPHQL
      #{graphql_field_alias}: repository(owner: "#{repo_owner}", name: "#{repo_name}") {
        pullRequest(number: #{number}) {
          isDraft
          mergeable
        }
      }
    GRAPHQL
    pull_graphql_fields << graphql_field
  end
end

graphql_data = {}
graphql_queries = []
graphql_queries << <<~GRAPHQL
  query {
    #{pull_graphql_fields.take(pull_fields_per_query).join("\n")}
  }
GRAPHQL
remaining_pull_fields = pull_graphql_fields.drop(pull_fields_per_query)
remaining_pull_fields.each_slice(pull_fields_per_query) do |pull_fields_in_batch|
  graphql_queries << <<~GRAPHQL
    query {
      #{pull_fields_in_batch.join("\n")}
    }
  GRAPHQL
end

logger.info("Will make #{graphql_queries.size} API request(s) to get pull request data") unless quiet_mode

graphql_queries.each_with_index do |graphql_query, query_index|
  logger.loading("Making API request #{query_index + 1} of #{graphql_queries.size}...") unless quiet_mode
  json_str = `#{gh_path} api graphql -f query='#{graphql_query}'`
  graphql_resp = JSON.parse(json_str)

  if graphql_resp["data"]
    graphql_data.merge!(graphql_resp["data"])
  else
    graphql_error_msg = if graphql_resp["errors"]
      graphql_resp["errors"].map { |err| err["message"] }.join("\n")
    else
      graphql_resp.inspect
    end
    logger.error("Error: no data returned from the GraphQL API")
    logger.error(graphql_error_msg)
    exit 1
  end
end

pp graphql_data
